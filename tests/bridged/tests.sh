# Systemd health
run_test "systemd_no_failed" "test -z \"\$(systemctl --failed --no-legend)\"" || ((FAILURES++))

# Bridged networking — VM should have a DHCP address on the LAN
run_test "network_interface_up" "ip addr show | grep -q 'state UP'" || ((FAILURES++))
run_test "network_has_ip" "ip -4 -o addr show scope global | grep -q ." || ((FAILURES++))
run_test "dns_resolution" "getent hosts nixos.org" || ((FAILURES++))
run_test "http_fetch" "curl -sf --max-time 10 -o /dev/null http://nixos.org" || ((FAILURES++))

# Verify we're actually bridged (not on the 192.168.64.0/24 NAT subnet)
run_test "not_nat_subnet" "! ip -4 -o addr show scope global | grep -q '192.168.64.'" || ((FAILURES++))
