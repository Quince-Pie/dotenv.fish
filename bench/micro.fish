source (status dirname)/../functions/dotenv.fish
set -l idx (string split ' ' (string repeat -n 200 'x '))
for f in $argv
    dotenv $f; or continue
    set -l t0 (date +%s%N)
    for i in $idx[1..60]; dotenv $f; end
    set -l t1 (date +%s%N)
    printf '%-14s %8.1f µs/file  %6.1f µs/value\n' (basename $f .env) (math "($t1-$t0)/60/1000") (math "($t1-$t0)/60/1000/20")
end
