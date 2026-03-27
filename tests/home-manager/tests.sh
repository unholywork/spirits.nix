# Basic VM health (sanity check)
run_test "nix_store_accessible" "test -d /nix/store" || ((FAILURES++))
run_test "systemd_no_failed" "test -z \"\$(systemctl --failed --no-legend)\"" || ((FAILURES++))

# Home-manager tests
run_test "hm_user_exists" "id testuser" || ((FAILURES++))
run_test "hm_home_dir" "test -d /home/testuser" || ((FAILURES++))
run_test "hm_bash_profile" "test -f /home/testuser/.bashrc" || ((FAILURES++))
run_test "hm_git_config" "su - testuser -c 'git config user.name'" || ((FAILURES++))
run_test "hm_git_email" "su - testuser -c 'git config user.email'" || ((FAILURES++))
