# usage: fish --no-config bench.fish REPS DASH BASH WORKLOAD [LOADER...]
# Per-call wall time of each loader on each workload, measured inside one warm
# fish process: REPS batches of B calls, B chosen so a batch takes ~60 ms.
source (status dirname)/loaders.fish
set -g BL_DASH $argv[2]
set -g BL_BASH $argv[3]
set -l reps $argv[1]
set -l dir (status dirname)/work
set -l idx (string split ' ' (string repeat -n 2000 'x ')) # iteration lists, no fork
set -l loaders $argv[5..-1]
set -q loaders[1]; or set loaders bl_dotenv bl_dash bl_bash bl_naive
for f in $argv[4]
    for L in $loaders
        # warm-up and batch size
        set -l t0 (date +%s%N)
        for i in $idx[1..5]
            $L $dir/$f.env >/dev/null 2>&1
        end
        set -l t1 (date +%s%N)
        set -l one (math "($t1 - $t0) / 5")
        set -l B (math "max(3, min(2000, floor(60000000 / $one)))")
        set -l per
        for r in $idx[1..$reps]
            set -l t0 (date +%s%N)
            for i in $idx[1..$B]
                $L $dir/$f.env
            end
            set -l t1 (date +%s%N)
            set -a per (math "($t1 - $t0) / $B / 1000")
        end
        set -l sorted (printf '%s\n' $per | sort -g)
        set -l mid (math "floor(($reps + 1) / 2)")
        printf '%-14s %-10s %8.1fµs %8.1fµs %8.1fµs %6s\n' $f $L $sorted[$mid] $sorted[1] $sorted[-1] $B
    end
end
