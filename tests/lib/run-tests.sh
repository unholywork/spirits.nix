#!/usr/bin/env bash
# Common test runner. Boots VM, waits for ready, then sources a test script.
# Usage: run-tests.sh <vm-script> <ssh-key> <test-script> [timeout]
set -euo pipefail

VM_SCRIPT="$1"
SSH_KEY="$2"
TEST_SCRIPT="$3"
TIMEOUT="${4:-120}"

SERIAL_LOG=$(mktemp)
cleanup() {
  kill "$VM_PID" 2>/dev/null || true
  wait "$VM_PID" 2>/dev/null || true
  rm -f "$SERIAL_LOG"
}
trap cleanup EXIT

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR -i "$SSH_KEY")

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

# Parse VM IP from sentinel line (format: SPIRITS_TEST_READY ip=x.x.x.x)
# Strip carriage returns — serial console output uses \r\n line endings.
VM_IP=$(grep -o 'ip=[^ ]*' "$SERIAL_LOG" | head -1 | cut -d= -f2 | tr -d '\r')
if [ -z "$VM_IP" ]; then
  echo "FAIL: Could not determine VM IP from serial log"
  exit 1
fi
echo "VM IP: $VM_IP"

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

# Test helper available to test scripts
run_test() {
  local name="$1"; shift
  printf "  %-30s " "$name"
  if output=$(ssh "${SSH_OPTS[@]}" "root@${VM_IP}" "$@" 2>&1); then
    echo "PASS"
    echo "    output: $output"
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

# Source the test-specific script
export -f run_test
export SSH_OPTS VM_IP
source "$TEST_SCRIPT"

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
