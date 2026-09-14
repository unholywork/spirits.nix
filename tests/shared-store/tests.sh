# The store comes from the host over virtio-fs, not from a squashfs disk.
run_test "ro_store_is_virtiofs" "findmnt -no SOURCE /nix/.ro-store | grep -q '^shares'" || ((FAILURES++))
run_test "no_squashfs_mount" "! mount | grep -q squashfs" || ((FAILURES++))
run_test "no_store_disk" "! test -e /dev/vda" || ((FAILURES++))

# Store and DB work as usual
run_test "nix_store_accessible" "test -d /nix/store" || ((FAILURES++))
run_test "nix_store_db_works" "nix-store -q --requisites /run/current-system | head -1" || ((FAILURES++))
run_test "nix_store_writable" "nix-store --add /etc/hostname" || ((FAILURES++))

# The whole host store is visible, not just this system's closure —
# nixpkgs#hello is in the host store because the test host built it.
run_test "nix_run_hello" "nix run nixpkgs#hello 2>/dev/null" || ((FAILURES++))

run_test "systemd_no_failed" "test -z \"\$(systemctl --failed --no-legend)\"" || ((FAILURES++))
