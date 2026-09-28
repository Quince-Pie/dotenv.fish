#!/bin/sh
# Each workload runs in a fresh fish process with the caller's environment.
here=$(cd "$(dirname "$0")" && pwd)
reps=${1:-9}; shift
dash=$(readlink -f "$here/../bin/dash"); bash=$(readlink -f "$here/../bin/bash")
printf '%-14s %-10s %9s %9s %9s %6s\n' workload loader 'median' 'min' 'max' B
for w in ${WORKLOADS:-small medium large refs heavy realistic}; do
  fish --no-config "$here/bench.fish" "$reps" "$dash" "$bash" "$w" "$@"
done
