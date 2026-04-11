run_test "persist_is_ext4" "mount | grep ' /persist ' | grep -q ext4" || ((FAILURES++))
run_test "persist_is_vda" "mount | grep ' /persist ' | grep -q /dev/vda" || ((FAILURES++))
run_test "persist_writable" "touch /persist/spirits-test && test -f /persist/spirits-test" || ((FAILURES++))
run_test "systemd_no_failed" "test -z \"\$(systemctl --failed --no-legend)\"" || ((FAILURES++))
