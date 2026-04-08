# Root filesystem is ext4 on /dev/vda (not tmpfs)
run_test "root_is_ext4" "mount | grep ' / ' | grep -q ext4" || ((FAILURES++))
run_test "root_is_vda" "mount | grep ' / ' | grep -q /dev/vda" || ((FAILURES++))

# Nix store overlay works on disk-backed root
run_test "nix_store_accessible" "test -d /nix/store" || ((FAILURES++))
run_test "nix_store_has_paths" "test \$(ls /nix/store/ | wc -l) -gt 0" || ((FAILURES++))
run_test "nix_store_db_works" "nix-store -q --requisites /run/current-system | head -1" || ((FAILURES++))

# Overlay has more space than the old 512M tmpfs
run_test "rw_store_not_tmpfs" "! mount | grep '/nix/.rw-store' | grep -q tmpfs" || ((FAILURES++))
run_test "rw_store_space_gt_1G" "test \$(df --output=avail /nix/.rw-store | tail -1) -gt 1048576" || ((FAILURES++))

# Nix commands work (the whole point — no more space issues)
run_test "nix_run_hello" "nix run nixpkgs#hello 2>/dev/null" || ((FAILURES++))

# Systemd health
run_test "systemd_no_failed" "test -z \"\$(systemctl --failed --no-legend)\"" || ((FAILURES++))
