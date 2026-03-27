# Nix store tests
run_test "nix_store_accessible" "test -d /nix/store" || ((FAILURES++))
run_test "nix_store_has_paths" "test \$(ls /nix/store/ | wc -l) -gt 0" || ((FAILURES++))
run_test "nix_store_db_works" "nix-store -q --requisites /run/current-system | head -1" || ((FAILURES++))
run_test "nix_run_hello" "nix run nixpkgs#hello 2>/dev/null" || ((FAILURES++))

# Networking tests
run_test "network_interface_up" "ip addr show | grep -q 'state UP'" || ((FAILURES++))
run_test "network_has_ip" "ip addr show | grep -q '192.168.64.200'" || ((FAILURES++))
run_test "dns_resolution" "getent hosts nixos.org" || ((FAILURES++))
run_test "http_fetch" "curl -sf --max-time 10 -o /dev/null http://nixos.org" || ((FAILURES++))

# Systemd health
run_test "systemd_no_failed" "test -z \"\$(systemctl --failed --no-legend)\"" || ((FAILURES++))
