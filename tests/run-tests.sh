#!/usr/bin/env bash
set -euo pipefail

VM_SCRIPT="$1"
SSH_KEY="$2"
TIMEOUT="${3:-120}"

SERIAL_LOG=$(mktemp)
cleanup() {
  kill "$VM_PID" 2>/dev/null || true
  wait "$VM_PID" 2>/dev/null || true
  rm -f "$SERIAL_LOG"
}
trap cleanup EXIT

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR -i "$SSH_KEY")
VM_IP="192.168.64.200"

# Record start time
START_NS=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')

# Launch VM in headless mode
"$VM_SCRIPT" --headless < /dev/null > "$SERIAL_LOG" 2>/dev/null &
VM_PID=$!

# Wait for boot sentinel
echo "Waiting for VM to boot (timeout: ${TIMEOUT}s)..."
DEADLINE=$((SECONDS + TIMEOUT))
BOOT_DETECTED=false
while [ $SECONDS -lt $DEADLINE ]; do
  if grep -q "SPIRITS_TEST_READY" "$SERIAL_LOG" 2>/dev/null; then
    BOOT_DETECTED=true
    break
  fi
  # Check VM is still running
  if ! kill -0 "$VM_PID" 2>/dev/null; then
    echo "FAIL: VM process exited unexpectedly"
    exit 1
  fi
  sleep 0.5
done

if ! $BOOT_DETECTED; then
  echo "FAIL: VM did not boot within ${TIMEOUT}s"
  exit 1
fi

END_NS=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')
BOOT_MS=$(( (END_NS - START_NS) / 1000000 ))
echo "Boot time: ${BOOT_MS}ms"

# Wait for SSH
echo "Waiting for SSH..."
SSH_DEADLINE=$((SECONDS + 30))
SSH_READY=false
while [ $SECONDS -lt $SSH_DEADLINE ]; do
  if ssh "${SSH_OPTS[@]}" "root@${VM_IP}" true 2>/dev/null; then
    SSH_READY=true
    break
  fi
  sleep 1
done

if ! $SSH_READY; then
  echo "FAIL: SSH not available within 30s after boot"
  exit 1
fi

# Boot profiling
echo ""
echo "=== Boot Profile ==="
ssh "${SSH_OPTS[@]}" "root@${VM_IP}" "systemd-analyze" 2>/dev/null || true
echo ""
ssh "${SSH_OPTS[@]}" "root@${VM_IP}" "systemd-analyze blame | head -10" 2>/dev/null || true

# Run tests
run_test() {
  local name="$1"; shift
  printf "  %-30s " "$name"
  if output=$(ssh "${SSH_OPTS[@]}" "root@${VM_IP}" "$@" 2>&1); then
    echo "PASS"
    return 0
  else
    echo "FAIL"
    echo "    output: $output"
    return 1
  fi
}

FAILURES=0
echo ""
echo "=== Test Results ==="
printf "  %-30s PASS (%dms)\n" "boot_time" "$BOOT_MS"

# Nix store tests
run_test "nix_store_accessible" "test -d /nix/store" || ((FAILURES++))
run_test "nix_store_has_paths" "test \$(ls /nix/store/ | wc -l) -gt 0" || ((FAILURES++))
run_test "nix_store_db_works" "nix-store -q --requisites /run/current-system | head -1" || ((FAILURES++))

# Networking tests
run_test "network_interface_up" "ip addr show | grep -q 'state UP'" || ((FAILURES++))
run_test "network_has_ip" "ip addr show | grep -q '192.168.64.200'" || ((FAILURES++))
run_test "dns_resolution" "getent hosts nixos.org" || ((FAILURES++))
run_test "http_fetch" "curl -sf --max-time 10 -o /dev/null http://nixos.org" || ((FAILURES++))

# Systemd health
run_test "systemd_running" "systemctl is-system-running" || ((FAILURES++))

echo ""
echo "=== Summary ==="
echo "Boot time: ${BOOT_MS}ms"
if [ "$FAILURES" -eq 0 ]; then
  echo "All tests passed."
else
  echo "${FAILURES} test(s) failed."
fi

# Shut down VM
ssh "${SSH_OPTS[@]}" "root@${VM_IP}" "poweroff" 2>/dev/null || true
sleep 2
kill "$VM_PID" 2>/dev/null || true

exit "$FAILURES"
