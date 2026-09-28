# Competing loaders for the benchmark. Only bl_dotenv is correct by
# construction; the others are the common alternatives found in the survey.

source (status dirname)/../functions/dotenv.fish

function bl_dotenv -a file
    dotenv $file
end

# Conventional control: let a POSIX shell source the file (set -a) and import
# every exported variable whose value changed. This is the mechanism of
# bass, replay.fish and plugin-foreign-env, reduced to its fastest form.
function __bl_import -a shell file
    set -l kv (command $shell -c 'set -a; . "$1" || exit 1; exec env -0' sh $file | string split0)
    or return 1
    for x in $kv
        set -l p (string split -m1 = -- $x)
        switch $p[1]
            case PWD SHLVL _ OLDPWD
                continue
        end
        if not set -q -x $p[1]; or test "$$p[1]" != "$p[2]"
            set -gx $p[1] $p[2]
        end
    end
end

function bl_dash -a file
    __bl_import $BL_DASH $file
end

function bl_bash -a file
    __bl_import $BL_BASH $file
end

# Typical line-oriented fish loader (the pattern of most fish dotenv plugins):
# split on the first `=`, strip `export`, one pair of quotes and comments.
function bl_naive -a file
    while read -l line
        set line (string trim -- $line)
        string match -qr '^(#|$)' -- $line; and continue
        set line (string replace -r '^export\s+' '' -- $line)
        set -l kv (string split -m1 = -- $line)
        set -q kv[2]; or continue
        set -l v (string replace -r '\s+#.*$' '' -- $kv[2])
        set v (string trim -c '"\'' -- $v)
        set -gx $kv[1] $v
    end <$file
end
