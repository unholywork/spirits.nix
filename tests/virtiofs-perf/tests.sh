# virtiofs perf tests
# Guards against continously degrading viertiofs performance in certain configurations

run_test "virtiofs_no_degradation" "bash -c '
times=()
for i in 1 2 3 4 5 6 7 8 9 10; do
  start=\$(date +%s%N)
  ls /nix/.ro-store/ > /dev/null 2>&1
  end=\$(date +%s%N)
  ms=\$(( (end - start) / 1000000 ))
  times+=(\$ms)
  echo \"run \$i: \${ms}ms\"
done
# last run should not be more than 3x slower than 1st
test \${times[9]} -lt \$(( \${times[0]} * 3 ))
'" || ((FAILURES++))
