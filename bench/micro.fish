# usage: fish --no-config micro.fish micro/*.env
# Cost per construct: each file holds 20 assignments of one kind. Five batches
# of 60 calls each; the median, minimum and maximum batch are reported, per
# file and per value.
source (status dirname)/../functions/dotenv.fish
set -l idx (string split ' ' (string repeat -n 200 'x '))
printf '%-14s %10s %10s %10s %11s\n' construct 'median' min max 'per value'
for f in $argv
    dotenv $f; or continue
    set -l per
    for r in 1 2 3 4 5
        set -l t0 (date +%s%N)
        for i in $idx[1..60]
            dotenv $f
        end
        set -l t1 (date +%s%N)
        set -a per (math "($t1 - $t0) / 60 / 1000")
    end
    set -l s (printf '%s\n' $per | sort -g)
    printf '%-14s %8.1fµs %8.1fµs %8.1fµs %9.1fµs\n' (basename $f .env) $s[3] $s[1] $s[5] (math "$s[3] / 20")
end
