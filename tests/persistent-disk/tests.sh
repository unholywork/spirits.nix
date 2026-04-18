run_test "persist_is_ext4" "mount | grep ' /persist ' | grep -q ext4" || ((FAILURES++))
run_test "persist_is_vda" "mount | grep ' /persist ' | grep -q /dev/vda" || ((FAILURES++))
run_test "persist_writable" "echo spirits-test > /persist/spirits-test && sync && test -f /persist/spirits-test" || ((FAILURES++))

printf "  %-30s " "persist_after_reboot"
before_uuid=$(ssh "${SSH_OPTS[@]}" "root@${VM_IP}" "blkid -s UUID -o value /dev/vda" 2>&1)
if [ $? -ne 0 ] || [ -z "$before_uuid" ]; then
  echo "FAIL"
  echo "    output: failed to read initial disk UUID: $before_uuid"
  ((FAILURES++))
else
  ssh "${SSH_OPTS[@]}" "root@${VM_IP}" "sh -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 &" >/dev/null 2>&1 || true

  went_down=false
  for _ in $(seq 1 30); do
    if ! ssh "${SSH_OPTS[@]}" "root@${VM_IP}" true >/dev/null 2>&1; then
      went_down=true
      break
    fi
    sleep 1
  done

  came_back=false
  if $went_down; then
    for _ in $(seq 1 60); do
      if ssh "${SSH_OPTS[@]}" "root@${VM_IP}" true >/dev/null 2>&1; then
        came_back=true
        break
      fi
      sleep 1
    done
  fi

  if ! $went_down; then
    echo "FAIL"
    echo "    output: VM never went down for reboot"
    ((FAILURES++))
  elif ! $came_back; then
    echo "FAIL"
    echo "    output: VM did not come back after reboot"
    ((FAILURES++))
  else
    if output=$(ssh "${SSH_OPTS[@]}" "root@${VM_IP}" "set -e; test \"\$(cat /persist/spirits-test)\" = spirits-test; after_uuid=\$(blkid -s UUID -o value /dev/vda); test \"$before_uuid\" = \"\$after_uuid\"; echo UUID=\$after_uuid" 2>&1); then
      echo "PASS"
      echo "    output: $output"
    else
      echo "FAIL"
      echo "    output: $output"
      ((FAILURES++))
    fi
  fi
fi

run_test "systemd_no_failed" "test -z \"\$(systemctl --failed --no-legend)\"" || ((FAILURES++))
