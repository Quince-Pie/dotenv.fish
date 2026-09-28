# dotenv — load POSIX shell .env files into fish.
#
# A file is interpreted exactly as a POSIX.1-2024 shell interprets
#     set -a; . ./FILE; set +a
# when started with fish's current environment, for the subset of the shell
# language made of variable assignments, `export`, comments, `;` and
# newlines. Everything outside that subset, and every construct whose meaning
# POSIX leaves unspecified or that conforming shells resolve differently, is
# rejected with a diagnostic. Nothing is assigned unless all input is valid.
#
# Local variables start with a digit. fish allows that and POSIX names do
# not, so no name that a .env file refers to can collide with one of ours.
# Variables created by `string match` capture groups live in short blocks.
# Values are joined with `printf %s … | string collect -N -a`, the only way
# to build a string in fish that neither splits on nor trims newlines.

function dotenv --description 'Load POSIX .env files into the environment (as `set -a; . FILE` would)'
    set -l 0print 0
    set -l 0files
    while set -q argv[1]
        switch $argv[1]
            case -h --help
                __dotenv_help
                return 0
            case -p --print
                set 0print 1
            case --
                set -a 0files $argv[2..-1]
                break
            case '-?*'
                printf 'dotenv: unknown option: %s\n' $argv[1] >&2
                return 2
            case '*'
                set -a 0files $argv[1]
        end
        set -e argv[1]
    end
    set -q 0files[1]; or set 0files .env

    # Sub-patterns shared by all regexes, called by number. They are unnamed
    # so that `string match` does not turn them into variables.
    #  1 blank or line continuation     2 comment     3 name
    #  4 special parameter              5 unquoted literal run
    #  6 \c '…' $'…' or "…"             7 $name ${…} or a lone $
    #  8 ${…} body outside "…"          9 ${…} body inside "…"
    # 10 word of ${x-word} etc. inside "…"
    # 11 word                           12 contents of "…"
    # 13 contents of $'…': only the escapes POSIX specifies, and none that
    #    yields a NUL or does not fit in a byte (checked even where unused)
    # U+00A0 and the other non-ASCII blanks end an unquoted run: whether they
    # separate words depends on the shell and locale, so they must be quoted.
    # Unbraced special parameters ($1 $$ $@ …) are not tokens at all, so that
    # e.g. `$${` (bash and zsh read `$` `${`) never gets a meaning. Inside
    # ${x-…} within "…", `$'` is refused too: yash and mksh read a quote.
    set -l 0def '(?x)(?(DEFINE)
        ([\x20\t]|\x5c\n)
        (\#[^\n]*+)
        ([A-Za-z_][A-Za-z0-9_]*+)
        ([0-9@*\#?$!-])
        ([^\x20\t\n;&|<>()\x5c\x27"$`\x{A0}\x{1680}\x{180E}\x{2000}-\x{200A}\x{202F}\x{205F}\x{3000}]++)
        (\x5c[\s\S]|\x27[^\x27]*+\x27|\$\x27(?13)\x27|"(?12)")
        (\$(?:\{(?8)\}|(?3)|(?=[\x20\t\n]|\z)))
        ((?:[^}\x5c\x27"$`]++|(?6)|(?7))*+)
        (\#(?3)|(?3)(?:(?:%%?+|\#\#?+)(?8)|:?+[-=?+](?10))?+|(?4)[^}]*+)
        ((?:[^}"\x5c$`]++|\x5c[\s\S]|\$(?:\{(?9)\}|(?3)|(?=[\x20\t\n])))*+)
        ((?:(?5)|(?6)|(?7))++)
        ((?:[^"\x5c$`]++|\x5c[\s\S]|\$(?:\{(?9)\}|(?3)|(?=[\x20\t\n\x27])))*+)
        ((?:[^\x27\x5c]++|\x5c["\x27\x5cabefnrtv]|\x5cc(?:\x5c\x5c|[A-Za-z\[\]^_?])
           |\x5cx(?!0{1,2}+(?![0-9A-Fa-f]))[0-9A-Fa-f]{1,2}+(?![0-9A-Fa-f])
           |\x5c(?!0{1,3}+(?![0-7]))(?:[0-3][0-7]{0,2}+|[4-7][0-7]?+(?![0-7])))*+)
    )'
    # Blanks, comments and separators before a word. s is `;` or a newline
    # when the word starts a new command.
    set -l 0gap '(?>(?1)*+(?|(?<s>;)(?1)*+(?2)?+(?:\n(?:[\x20\t\n]|\x5c\n|(?2))*+)?+
                   |(?2)?+(?<s>\n)(?:[\x20\t\n]|\x5c\n|(?2))*+
                   |(?2)?+(?=\z))?+)'
    # x: `export ` prefix. n/v: an assignment whose value needs no decoding
    # beyond removing one pair of quotes. n/r: any other assignment (raw
    # value). w: any other word. e: text that cannot be tokenized.
    set -l 0word '(?:(?<x>export(?1)++(?:--(?1)++)?+)?+
           (?<n>[A-Za-z_][A-Za-z0-9_]*+)=
           (?:(?|(?<v>(?!~)(?:[^\x20\t\n;&|<>()\x5c\x27"$`:\x{A0}\x{1680}\x{180E}\x{2000}-\x{200A}\x{202F}\x{205F}\x{3000}]++|:(?!~))*+)
                |\x27(?<v>[^\x27]*+)\x27
                |"(?<v>[^"\x5c$`]*+)")
              (?=[\x20\t\n;]|\z)
             |(?<r>(?11)?+))
          |(?<w>(?11))
          |(?<e>[^\n]++))'
    set -l 0re $0def'\G'$0gap$0word
    # Pieces of a word outside "…" (K: kind, V: text) and inside "…".
    set -l 0pu $0def'\G(?|(?<K>)(?<V>[^\x5c\x27"$`~:/]++)
        |(?<K>[~:/])(?<V>)
        |(?<K>\x5c)(?<V>[\s\S])
        |(?<K>\x27)(?<V>[^\x27]*+)\x27
        |(?<K>\$\x27)(?<V>(?13))\x27
        |(?<K>")(?<V>(?12))"
        |(?<K>\$\{)(?<V>(?8))\}
        |(?<K>\$)(?<V>(?3)|(?=[\x20\t\n]|\z)))
        |(?<Z>[\s\S])'
    set -l 0pd $0def'\G(?|(?<K>)(?<V>[^\x5c"$`]++)
        |(?<K>\x5c)(?<V>[\s\S])
        |(?<K>\$\{)(?<V>(?9))\}
        |(?<K>\$)(?<V>(?3)|(?=[\x20\t\n\x27]|\z)))
        |(?<Z>[\s\S])'

    set -l 0cn # names to assign, in execution order (duplicates allowed)
    set -l 0cv # their values
    set -l 0en # snapshot of the environment: exported names
    set -l 0ev # ... and their values
    set -l 0eu # names known not to be exported
    set -l 0err # error message, set by helpers
    set -l 0res # result of the last helper
    set -l 0lset # set by __dotenv_lookup: 1 if the parameter is set
    set -l 0utf8 # 1/0 once known: is the environment's LC_CTYPE UTF-8?
    set -l 0pwild # set by __dotenv_pattern: ? or […] used
    set -l 0pclass # set by __dotenv_pattern: [:class:] used

    for 0f in $0files
        set -l 0text
        if test "$0f" = -
            set 0text (string split0)
        else if test -d "$0f"
            printf 'dotenv: %s: is a directory\n' (__dotenv_vis $0f) >&2
            return 1
        else if not test -r "$0f"
            if test -e "$0f"
                printf 'dotenv: %s: permission denied\n' (__dotenv_vis $0f) >&2
            else
                printf 'dotenv: %s: no such file\n' (__dotenv_vis $0f) >&2
            end
            return 1
        else
            set 0text (string split0 <$0f)
        end
        switch $status
            case 0
                # string split0 only succeeds if it split something.
                printf 'dotenv: %s: file contains a NUL byte\n' (__dotenv_vis $0f) >&2
                return 1
            case 122
                printf 'dotenv: %s: file exceeds $fish_read_limit\n' (__dotenv_vis $0f) >&2
                return 1
        end
        # Shell input must be text (2.3, XBD 3.387): in a UTF-8 locale, bytes
        # that are not UTF-8 (kept by fish as U+F600…U+F6FF) are undefined.
        if string match -rq -- '[\x{F600}-\x{F6FF}]' "$0text"
            set -l 0loc
            for 0nm in LC_ALL LC_CTYPE LANG
                if set -q -x $0nm; and test -n "$$0nm"
                    set 0loc "$$0nm"
                    break
                end
            end
            if string match -rqi -- 'utf-?8' "$0loc"
                printf 'dotenv: %s: not valid UTF-8, as the %s locale requires\n' (__dotenv_vis $0f) (__dotenv_vis $0loc) >&2
                return 1
            end
        end
        # A leading newline makes the first word start a command, so that a
        # leading `;` is rejected like any other stray `;`.
        set 0text \n"$0text"

        set -l 0simple 1
        begin
            set -l s
            set -l x
            set -l n
            set -l v
            set -l r
            set -l w
            set -l e
            string match -raq -- $0re $0text 2>/dev/null
            if test $status -gt 1
                set 0simple 2
            else if string length -q -- $r $w $e ''
                set 0simple 0
                set -f 0S $s
                set -f 0X $x
                set -f 0N $n
                set -f 0V $v
                set -f 0R $r
                set -f 0W $w
                set -f 0E $e
            else
                set -a 0cn $n
                set -a 0cv $v
            end
        end
        if test $0simple = 2
            printf 'dotenv: %s: input too large or deeply nested for the tokenizer\n' (__dotenv_vis $0f) >&2
            return 1
        end
        test $0simple = 1; and continue

        # Snapshot every environment variable the file may refer to before
        # any helper runs, so that no local variable can shadow it.
        begin
            set -l q
            string match -raq -- '\$\{?\#?(?<q>[A-Za-z_][A-Za-z0-9_]*+)' $0text
            set -f 0refs $q HOME LC_ALL LC_CTYPE LC_COLLATE LANG
        end
        for 0nm in $0refs
            contains -- $0nm $0en $0eu; and continue
            if test $0nm = argv
                # A function cannot read a global `argv`; refuse rather than guess.
                if set -q -g -x argv; or set -q -U -x argv
                    __dotenv_fail $0f 1 "cannot read the exported variable 'argv' from a fish function"
                    return 1
                end
                set -a 0eu argv
            else if set -q -x $0nm
                set -a 0en $0nm
                set -a 0ev "$$0nm"
            else
                set -a 0eu $0nm
            end
        end

        set -l 0cmd
        for 0i in (__dotenv_seq (count $0N))
            if test -n "$0E[$0i]"
                __dotenv_fail $0f (__dotenv_line $0i) (__dotenv_syntax $0E[$0i])
                return 1
            end
            if test -n "$0S[$0i]"; and set -q 0cmd[1]
                if not __dotenv_command
                    __dotenv_fail $0f (__dotenv_line $0cmd[1]) $0err
                    return 1
                end
                set 0cmd
            end
            set -a 0cmd $0i
        end
        if set -q 0cmd[1]; and not __dotenv_command
            __dotenv_fail $0f (__dotenv_line $0cmd[1]) $0err
            return 1
        end
    end

    set -q 0cn[1]; or return 0

    # fish refuses to set these; umask would change the process umask.
    set -l 0bad (string match -r -- '^(?:FISH_VERSION|PWD|SHLVL|_|__fish_(?:bin|cache|config|data|help|man|sysconf|user_data)_dir|fish_(?:kill_signal|killring|pid|terminal_color_theme)|history|hostname|pipestatus|status|status_generation|umask|version)$' $0cn '')
    if set -q 0bad[1]
        printf 'dotenv: cannot set %s: it is a read-only or special fish variable\n' $0bad[1] >&2
        return 1
    end

    # fish rewrites some values on assignment: it canonicalizes HOME (runs of
    # slashes, a trailing slash) and turns empty PATH/CDPATH entries into `.`.
    # The environment would then differ from the shell's, so refuse instead.
    for 0nm in HOME PATH CDPATH
        set -l 0j (contains -i -- $0nm $0cn[-1..1])
        set -q 0j[1]; or continue
        set -l 0rv $0cv[-1..1]
        if not __dotenv_keeps $0nm $0rv[$0j]
            printf 'dotenv: fish would store %s as %s rather than %s; the result would differ from a POSIX shell\n' $0nm (__dotenv_keeps $0nm $0rv[$0j] 2>&1 | string escape) (string escape -- $0rv[$0j]) >&2
            return 1
        end
    end

    if test $0print = 1
        for 0i in (__dotenv_seq (count $0cn))
            printf 'set -gx %s %s\n' $0cn[$0i] (string escape -- $0cv[$0i])
        end
        return 0
    end

    if not set -q 0cn[2]
        set -g -x -- $0cn[1] $0cv[1]; or return 1
        return 0
    end
    # Assign everything with a single `read`: the values are joined with a
    # delimiter that none of them contains and split back by `read -d`.
    set -l 0d \x1e\x1f\x1e
    while string match -q -e -- $0d $0cv
        set 0d $0d\x1f
    end
    begin
        printf "%s$0d" $0cv[1..-2]
        printf %s $0cv[-1]
    end | read -z -g -x -d $0d $0cn
    if test $status -gt 1
        # Not expected (the names are validated); assign one at a time.
        for 0i in (__dotenv_seq (count $0cn))
            set -g -x -- $0cn[$0i] $0cv[$0i]; or return 1
        end
    end
    return 0
end

# Whether fish stores value $argv[2] for variable $argv[1] unchanged (tested
# on a local, which triggers no event). If not, prints the stored form.
function __dotenv_keeps -a 0nm 0val
    set -l $0nm $0val
    test "$$0nm" = "$0val"; and return 0
    printf %s "$$0nm"
    return 1
end

# 1 … $argv[1], one per line, without running the external `seq`.
function __dotenv_seq -a 0n
    test $0n -gt 0; and string split -f1 ' ' -- (string match -ran . -- (string repeat -n $0n x))
end

# Run the simple command formed by the items in $0cmd. Words are expanded and
# assigned in the order of POSIX 2.9.1; results are appended to $0cn/$0cv.
function __dotenv_command -S
    # Common case: one assignment whose value needs no expansion.
    if not set -q 0cmd[2]
        set -l 0j $0cmd[1]
        if test -z "$0R[$0j]$0W[$0j]"
            set -a 0cn $0N[$0j]
            set -a 0cv $0V[$0j]
            return 0
        end
    end

    # Classify the words: A assignment, E `export`, D `--`, B bare name,
    # O anything else. 0wn: name or text, 0wv: literal value, 0wr: raw value.
    set -l 0wk
    set -l 0wn
    set -l 0wv
    set -l 0wr
    for 0j in $0cmd
        if test -n "$0X[$0j]"
            set -a 0wk E
            set -a 0wn export
            set -a 0wv ''
            set -a 0wr ''
            if string match -q -- '*--*' $0X[$0j]
                set -a 0wk D
                set -a 0wn --
                set -a 0wv ''
                set -a 0wr ''
            end
        end
        if test -n "$0N[$0j]"
            set -a 0wk A
            set -a 0wn $0N[$0j]
            set -a 0wv $0V[$0j]
            set -a 0wr $0R[$0j]
            continue
        end
        # A word that is a name, `export` or an assignment only once its line
        # continuations are removed, such as `A\<newline>B=1`.
        set -l 0t $0W[$0j]
        set -l Gn
        set -l Gr
        if string match -rq -- '\A(?<Gn>(?:[A-Za-z_]|\x5c\n)(?:[A-Za-z0-9_]|\x5c\n)*+)=(?<Gr>[\s\S]*+)\z' $0t
            set -a 0wk A
            set -a 0wn (string replace -a \\\n '' -- $Gn)
            set -a 0wv ''
            set -a 0wr $Gr
            continue
        end
        set -a 0wv ''
        set -a 0wr ''
        if string match -rq -- '\A(?:[A-Za-z0-9_-]|\x5c\n)++\z' $0t
            set 0t (string replace -a \\\n '' -- $0t)
            switch $0t
                case export
                    set -a 0wk E
                case --
                    set -a 0wk D
                case '*'
                    if string match -rq -- '\A[A-Za-z_][A-Za-z0-9_]*\z' $0t
                        set -a 0wk B
                    else
                        set -a 0wk O
                    end
            end
        else
            set -a 0wk O
        end
        set -a 0wn $0t
    end

    # Leading assignments, then (if present) `export` and its operands.
    set -l 0pre
    set -l 0ops
    set -l 0exp 0
    set -l 0dd 0
    for 0k in (__dotenv_seq (count $0wk))
        if test $0exp = 0
            switch $0wk[$0k]
                case A
                    set -a 0pre $0k
                case E
                    set 0exp 1
                case '*'
                    set 0err (__dotenv_cmderr $0wk[$0k] $0wn[$0k])
                    return 1
            end
        else
            switch $0wk[$0k]
                case A B E
                    # (E here is the operand `export`, a valid name.)
                    set -a 0ops $0k
                case D
                    if test $0dd = 0 -a -z "$0ops"
                        set 0dd 1
                    else
                        set 0err "export: invalid operand '--'"
                        return 1
                    end
                case '*'
                    set 0err "export: unsupported operand '$0wn[$0k]'"
                    return 1
            end
        end
    end

    if test $0exp = 0
        for 0k in $0pre
            __dotenv_value $0k; or return 1
            set -a 0cn $0wn[$0k]
            set -a 0cv $0res
        end
        return 0
    end

    if not set -q 0ops[1]
        set 0err "'export' without operands is not supported (its output is unspecified)"
        return 1
    end
    # The operands are expanded before the command runs (2.9.1.1 step 2),
    # then the leading assignments are made (step 4), then export assigns.
    set -l 0opn
    set -l 0opv
    for 0k in $0ops
        test $0wk[$0k] = A; or continue
        __dotenv_value $0k; or return 1
        set -a 0opn $0wn[$0k]
        set -a 0opv $0res
    end
    for 0k in $0pre
        __dotenv_value $0k; or return 1
        set -a 0cn $0wn[$0k]
        set -a 0cv $0res
    end
    set -a 0cn $0opn
    set -a 0cv $0opv
    return 0
end

# Value of assignment word $argv[1] of the current command, into $0res.
function __dotenv_value -S -a 0k
    if test -n "$0wr[$0k]"
        __dotenv_word $0wr[$0k] a
        return
    end
    set 0res $0wv[$0k]
    return 0
end

# Expand a word and remove quotes; the result goes to $0res.
# Modes: a  value of an assignment: tilde expansion at the start and after
#           every unquoted colon (2.6.1)
#        u  word of ${x-word} etc. outside double quotes
#        d  contents of "…"
#        D  word of ${x-word} etc. inside "…" (2.2.3)
function __dotenv_word -S -a 0raw 0mode
    set -l K
    set -l V
    set -l Z
    set -l 0uq 1 # unquoted context
    if test $0mode = a -o $0mode = u
        string match -raq -- $0pu $0raw 2>/dev/null
    else
        set 0uq 0
        string match -raq -- $0pd $0raw 2>/dev/null
    end
    if test $status -gt 1
        set 0err "word too large or deeply nested"
        return 1
    end
    if string length -q -- $Z ''
        set 0err (__dotenv_badchar (printf %s $Z))
        return 1
    end
    set -l 0out
    set -l 0tl 1 # 1: the next piece may start a tilde prefix
    set -l 0tp 0 # 1: inside a tilde prefix
    set -l 0login ''
    set -l 0colon 0 # previous piece was an unquoted colon
    for 0p in (__dotenv_seq (count $K))
        set -l 0k $K[$0p]
        set -l 0v $V[$0p]
        if test $0tp = 1
            if test -z "$0k" -a -z "$0login"
                set 0login $0v
                continue
            end
            # The prefix ends here: at a slash or (assignments) a colon.
            if not test "$0k" = / -o \( "$0k" = : -a $0mode = a \)
                set 0err "unsupported tilde prefix '~$0login…' (a login name must be followed by '/' or the end of the word)"
                return 1
            end
            __dotenv_tilde $0login $0k; or return 1
            set -a 0out $0res
            set 0tp 0
        end
        set -l 0wastl $0tl
        set 0tl 0
        set -l 0wascolon $0colon
        set 0colon 0
        switch $0k
            case ''
                set -a 0out $0v
            case '~'
                if test $0wastl = 1 -a $0uq = 1
                    set 0tp 1
                    set 0login ''
                else if test $0wascolon = 1 -a $0mode = u
                    set 0err "'~' after ':' inside \${…} is expanded by some shells and not by others"
                    return 1
                else
                    set -a 0out '~'
                end
            case :
                set -a 0out :
                set 0colon 1
                test $0mode = a; and set 0tl 1
            case /
                set -a 0out /
            case \\
                if test $0uq = 1
                    test "$0v" = \n; or set -a 0out $0v
                else
                    switch $0v
                        case \n
                        case \$ \` \" \\
                            set -a 0out $0v
                        case '}'
                            if test $0mode = D
                                set -a 0out '}'
                            else
                                set -a 0out '\\}'
                            end
                        case '*'
                            set -a 0out \\$0v
                    end
                end
            case \'
                set -a 0out $0v
            case \$\'
                __dotenv_dsq $0v; or return 1
                set -a 0out $0res
            case \"
                __dotenv_word $0v d; or return 1
                set -a 0out $0res
            case \$\{
                if test $0uq = 1
                    __dotenv_param $0v u; or return 1
                else
                    __dotenv_param $0v q; or return 1
                end
                set -a 0out $0res
            case \$
                if test -z "$0v"
                    set -a 0out \$
                else if string match -rq -- '\A[A-Za-z_]' $0v
                    __dotenv_lookup $0v; or return 1
                    set -a 0out $0res
                else
                    set 0err "special parameter \$$0v is not supported"
                    return 1
                end
        end
    end
    if test $0tp = 1
        __dotenv_tilde $0login ''; or return 1
        set -a 0out $0res
    end
    set 0res (printf %s $0out | string collect -N -a)
    return 0
end

# Home directory for the tilde prefix ~$argv[1]; $argv[2] is what follows it.
function __dotenv_tilde -S -a 0login 0next
    set -l 0home
    if test -z "$0login"
        __dotenv_lookup HOME; or return 1
        if test "$0lset" = 0
            set 0err "'~' needs HOME, which is not set"
            return 1
        end
        set 0home $0res
    else
        # 2.6.1: anything but a portable login name is unspecified.
        if not string match -rq -- '\A[A-Za-z0-9._-]++\z' $0login
            set 0err "'~$0login': not a portable login name"
            return 1
        end
        eval "set 0home ~$0login"
        if string match -q -- '~*' "$0home"
            set 0err "'~$0login': unknown user (unspecified)"
            return 1
        end
    end
    # 2.6.1 only recommends ("should") dropping the pathname's trailing slash
    # when a slash follows; dash, bash, busybox, mksh and zsh keep it, yash
    # and ksh93 drop it.
    if test "$0next" = /; and string match -q -- '*/' "$0home"
        set 0err "'~/' with a home directory ending in '/' ($0home) gives '//' in some shells and '/' in others"
        return 1
    end
    set 0res $0home
    return 0
end

# ${…} with body $argv[1]; $argv[2] is u (outside "…") or q (inside).
function __dotenv_param -S -a 0body 0ctx
    set -l Bl
    set -l Bn
    set -l Bo
    set -l Bw
    if not string match -rq -- '\A(?|(?<Bl>\#)(?<Bn>[A-Za-z_][A-Za-z0-9_]*+)(?<Bo>)(?<Bw>)|(?<Bl>)(?<Bn>[A-Za-z_][A-Za-z0-9_]*+)(?:(?<Bo>:?[-=?+]|%%?|\#\#?)(?<Bw>[\s\S]*+))?+)\z' $0body
        if string match -rq -- '\A\#?[0-9@*\#?$!-]' $0body
            set 0err "special parameter in \${$0body} is not supported"
        else
            set 0err "bad substitution: \${$0body}"
        end
        return 1
    end
    __dotenv_lookup $Bn; or return 1
    set -l 0set $0lset
    set -l 0val $0res
    if test -n "$Bl"
        __dotenv_length $0val
        return
    end
    set -l 0wm u
    test $0ctx = q; and set 0wm D
    set -l 0null 0
    test -z "$0val"; and set 0null 1
    switch "$Bo"
        case ''
            set 0res $0val
        case - :-
            if test $0set = 0 -o \( "$Bo" = :- -a $0null = 1 \)
                __dotenv_word "$Bw" $0wm; or return 1
            else
                set 0res $0val
            end
        case = :=
            if test $0set = 0 -o \( "$Bo" = := -a $0null = 1 \)
                __dotenv_word "$Bw" $0wm; or return 1
                set -a 0cn $Bn
                set -a 0cv $0res
            else
                set 0res $0val
            end
        case \? :\?
            if test $0set = 0 -o \( "$Bo" = :\? -a $0null = 1 \)
                if test -n "$Bw"
                    __dotenv_word "$Bw" $0wm; or return 1
                    set 0err "$Bn: $0res"
                else if test $0set = 0
                    set 0err "$Bn: parameter not set"
                else
                    set 0err "$Bn: parameter null or not set"
                end
                return 1
            end
            set 0res $0val
        case + :+
            if test $0set = 1 -a \( "$Bo" = + -o $0null = 0 \)
                __dotenv_word "$Bw" $0wm; or return 1
            else
                set 0res ''
            end
        case '*'
            # % %% # ##: remove the smallest/largest suffix/prefix.
            set -l 0star '.*'
            test "$Bo" = '#'; and set 0star '.*?'
            __dotenv_pattern "$Bw" $0star; or return 1
            __dotenv_strip "$Bo" $0val $0res; or return 1
    end
    return 0
end

# Value of the parameter $argv[1]: 0lset=1 and 0res=value if it is set.
function __dotenv_lookup -S -a 0nm
    set 0lset 1
    # The most recent assignment made by the files so far.
    set -l 0j (contains -i -- $0nm $0cn[-1..1])
    if set -q 0j[1]
        set -l 0rv $0cv[-1..1]
        set 0res $0rv[$0j]
        return 0
    end
    switch $0nm
        case IFS
            # 2.5.3: the shell sets IFS to <space><tab><newline> when invoked.
            set 0res ' '\t\n
            return 0
        case LINENO OPTIND PPID PS1 PS2 PS4
            set 0err "\$$0nm is set by the shell itself, not taken from the environment; it is not supported"
            return 1
    end
    set 0j (contains -i -- $0nm $0en)
    if set -q 0j[1]
        set 0res $0ev[$0j]
        return 0
    end
    set 0lset 0
    set 0res ''
    return 0
end

# ${#name}: the length in characters.
function __dotenv_length -S -a 0val
    if string match -rq -- '[^\x00-\x7F]' $0val
        __dotenv_chars $0val; or return 1
    end
    set 0res (string length -- $0val)
    return 0
end

# Non-ASCII text is handled as characters only when that is unambiguous: it
# is valid UTF-8 (fish keeps invalid bytes as U+F600…U+F6FF) and the locale
# the shell starts with is UTF-8. Shells differ on whether assigning LC_* or
# LANG changes their own locale, so that makes it ambiguous too.
function __dotenv_chars -S -a 0val
    if string match -rq -- '[\x{F600}-\x{F6FF}]' $0val
        set 0err "character semantics of a value that is not valid UTF-8 are unspecified"
        return 1
    end
    __dotenv_locale_fixed LC_CTYPE; or return 1
    if test -z "$0utf8"
        __dotenv_locale LC_CTYPE
        set 0utf8 0
        string match -rqi -- 'utf-?8' $0res; and set 0utf8 1
    end
    if test $0utf8 = 0
        set 0err "character semantics of non-ASCII text depend on a locale that is not UTF-8"
        return 1
    end
    return 0
end

# The environment's value for locale category $argv[1] (LC_ALL, then the
# category, then LANG), into $0res; empty means the POSIX locale.
function __dotenv_locale -S -a 0cat
    for 0nm in LC_ALL $0cat LANG
        set -l 0j (contains -i -- $0nm $0en)
        if set -q 0j[1]; and test -n "$0ev[$0j]"
            set 0res $0ev[$0j]
            return 0
        end
    end
    set 0res ''
    return 0
end

# Fails if the files assigned a variable that selects category $argv[1].
function __dotenv_locale_fixed -S -a 0cat
    for 0nm in LC_ALL $0cat LANG
        if contains -- $0nm $0cn
            set 0err "the file assigns $0nm; whether that changes the shell's own locale differs between shells"
            return 1
        end
    end
    return 0
end

# The pattern word of ${x%word} etc. as a PCRE fragment in $0res. Quoted
# characters match themselves; unquoted * ? and […] are special (2.14).
# Consecutive unquoted characters are globbed together so that e.g.
# [[:space:]] is one bracket expression. $argv[2] is the regex for `*`.
function __dotenv_pattern -S -a 0raw 0star
    set -l K
    set -l V
    set -l Z
    string match -raq -- $0pu $0raw 2>/dev/null
    if test $status -gt 1
        set 0err "pattern too large or deeply nested"
        return 1
    end
    if string length -q -- $Z ''
        set 0err (__dotenv_badchar (printf %s $Z))
        return 1
    end
    set 0pwild 0
    set 0pclass 0
    set -l 0out
    set -l 0buf # unquoted literal text not yet globbed
    set -l 0tp 0 # 1: inside a leading tilde prefix
    set -l 0login ''
    set -l 0colon 0
    for 0p in (__dotenv_seq (count $K))
        set -l 0k $K[$0p]
        set -l 0v $V[$0p]
        if test $0tp = 1
            if test -z "$0k" -a -z "$0login"
                set 0login $0v
                continue
            end
            if test "$0k" != /
                set 0err "unsupported tilde prefix '~$0login…' (a login name must be followed by '/' or the end of the word)"
                return 1
            end
            __dotenv_tilde $0login /; or return 1
            set -a 0out (string escape --style=regex -- $0res)
            set 0tp 0
        end
        set -l 0wascolon $0colon
        set 0colon 0
        switch $0k
            case ''
                set -a 0buf $0v
                continue
            case :
                set -a 0buf :
                set 0colon 1
                continue
            case /
                set -a 0buf /
                continue
            case '~'
                if test $0p = 1
                    set 0tp 1
                    continue
                else if test $0wascolon = 1
                    set 0err "'~' after ':' inside \${…} is expanded by some shells and not by others"
                    return 1
                end
                set -a 0buf '~'
                continue
        end
        if set -q 0buf[1]
            __dotenv_glob (printf %s $0buf | string collect -N -a) $0star; or return 1
            set -a 0out $0res
            set 0buf
        end
        switch $0k
            case \\
                test "$0v" = \n; or set -a 0out (string escape --style=regex -- $0v)
            case \'
                set -a 0out (string escape --style=regex -- $0v)
            case \$\'
                __dotenv_dsq $0v; or return 1
                set -a 0out (string escape --style=regex -- $0res)
            case \"
                __dotenv_word $0v d; or return 1
                set -a 0out (string escape --style=regex -- $0res)
            case \$\{ \$
                if test $0k = \$
                    if test -z "$0v"
                        set -a 0out '\$'
                        continue
                    end
                    if not string match -rq -- '\A[A-Za-z_]' $0v
                        set 0err "special parameter \$$0v is not supported"
                        return 1
                    end
                    __dotenv_lookup $0v; or return 1
                else
                    __dotenv_param $0v u; or return 1
                end
                # An unquoted expansion inside a pattern is itself a pattern.
                if string match -rq -- '[\[\x5c]' $0res
                    set 0err "unquoted expansion in a pattern yields '[' or '\\'; quote the expansion"
                    return 1
                end
                __dotenv_glob $0res $0star; or return 1
                set -a 0out $0res
        end
    end
    if test $0tp = 1
        __dotenv_tilde $0login ''; or return 1
        set -a 0out (string escape --style=regex -- $0res)
    end
    if set -q 0buf[1]
        __dotenv_glob (printf %s $0buf | string collect -N -a) $0star; or return 1
        set -a 0out $0res
    end
    set 0res (printf %s $0out | string collect -N -a)
    return 0
end

# Unquoted pattern text into a PCRE fragment. $argv[2]: regex for `*`.
function __dotenv_glob -S -a 0t 0star
    # K: '' literal text, * or ?, [ with V the bracket contents, or a lone [.
    set -l K
    set -l V
    string match -raq -- '\G(?|(?<K>)(?<V>[^*?[]++)|(?<K>[*?])(?<V>)|(?<K>\[)(?<V>!?+\]?+(?:\[:[a-z]++:\]|[^\]\[])*+)\]|(?<K>\[)(?<V>))' $0t
    set -l 0out
    for 0p in (__dotenv_seq (count $K))
        set -l 0k $K[$0p]
        set -l 0v $V[$0p]
        if test -z "$0k"
            set -a 0out (string escape --style=regex -- $0v)
        else if test "$0k" = '*'
            set -a 0out $0star
        else if test "$0k" = '?'
            set 0pwild 1
            set -a 0out .
        else if test -z "$0v"
            set 0err "'[' that does not start a bracket expression is not supported in patterns"
            return 1
        else
            __dotenv_bracket $0v; or return 1
            set -a 0out $0res
        end
    end
    set 0res (printf %s $0out | string collect -N -a)
    return 0
end

# A bracket expression (its contents, without the brackets) as a PCRE class.
# Supported: ASCII characters, [:class:] and, in the POSIX locale only,
# ranges; equivalence classes and collating symbols are not.
function __dotenv_bracket -S -a 0in
    set 0pwild 1
    set -l 0b "[$0in]"
    set -l 0neg ''
    if string match -q -- '!*' $0in
        set 0neg '^'
        set 0in (string sub -s 2 -- $0in)
    end
    if string match -q -- '^*' $0in
        set 0err "bracket expression $0b starts with '^', which is unspecified; use '!'"
        return 1
    end
    set -l 0cls 'alnum|alpha|blank|cntrl|digit|graph|lower|print|punct|space|upper|xdigit'
    if not string match -rq -- '\A\]?+(?:\[:(?:'$0cls'):\]|[\x20-\x5a\x5e-\x7e])*+\z' $0in
        set 0err "unsupported bracket expression $0b (only ASCII characters, [:class:] and ranges are)"
        return 1
    end
    # T: [: for a class, - for a range A-B, empty for the single character A.
    set -l T
    set -l A
    set -l B
    string match -raq -- '\G(?|(?<T>\[:)(?<A>'$0cls')(?<B>):\]|(?=[^\[](?<T>-)[^\[\]])(?<A>[^\[])-(?<B>[^\[\]])|(?<T>)(?<A>[^\[])(?<B>))' $0in
    set -l 0out
    for 0p in (__dotenv_seq (count $T))
        switch "$T[$0p]"
            case '[:'
                set 0pclass 1
                set -a 0out "[:$A[$0p]:]"
            case -
                # Ranges are only specified in the POSIX locale (XBD 9.3.5).
                __dotenv_locale_fixed LC_COLLATE; or return 1
                __dotenv_locale LC_COLLATE
                if not contains -- "$0res" '' C POSIX
                    set 0err "range expression $0b is unspecified outside the POSIX locale (collation is '$0res'); list the characters"
                    return 1
                end
                if test (printf %d "'$A[$0p]") -gt (printf %d "'$B[$0p]")
                    set 0err "range $A[$0p]-$B[$0p] in $0b is empty or invalid"
                    return 1
                end
                set -a 0out (string replace -r -- '^[^A-Za-z0-9]' '\\\\$0' $A[$0p])-(string replace -r -- '^[^A-Za-z0-9]' '\\\\$0' $B[$0p])
            case '*'
                set -a 0out (string replace -r -- '^[^A-Za-z0-9]' '\\\\$0' $A[$0p])
        end
    end
    set 0res "[$0neg"(string join '' -- $0out)"]"
    return 0
end

# Remove from $argv[2] the prefix or suffix ($argv[1]) matched by PCRE
# fragment $argv[3]. Lazy/greedy repetition gives the smallest/largest one.
function __dotenv_strip -S -a 0op 0val 0pat
    if test $0pwild = 1; and string match -rq -- '[^\x00-\x7F]' $0val
        __dotenv_chars $0val; or return 1
        if test $0pclass = 1
            set 0err "character classes on non-ASCII text are not supported"
            return 1
        end
    end
    switch $0op
        case '#' '##'
            set 0pat '(?s)\A(?:'$0pat')(?<R>.*+)\z'
        case '%'
            set 0pat '(?s)\A(?<R>.*)(?:'$0pat')\z'
        case '%%'
            set 0pat '(?s)\A(?<R>.*?)(?:'$0pat')\z'
    end
    set -l R
    string match -rq -- $0pat $0val 2>/dev/null
    switch $status
        case 0
            set 0res "$R"
        case 1
            set 0res $0val
        case '*'
            set 0err "pattern matching exceeded PCRE2's limits"
            return 1
    end
    return 0
end

# $'…' (2.2.4). printf produces the bytes, so that e.g. \xc3\xa9 becomes one
# character, as in a shell; only the escapes POSIX specifies are accepted.
function __dotenv_dsq -S -a 0raw
    set -l K
    set -l V
    set -l Z
    string match -raq -- '\G(?|(?<K>)(?<V>[^\x5c]++)|(?<K>\x5c)(?<V>["\x27\x5cabefnrtv])|(?<K>\x5cc)(?<V>\x5c\x5c|[\s\S])|(?<K>\x5cx)(?<V>[0-9A-Fa-f]{1,2}+)(?![0-9A-Fa-f])|(?<K>\x5c)(?<V>[0-7]{1,3}+))|(?<Z>[\s\S])' $0raw
    if string length -q -- $Z ''
        set 0err "unspecified escape in \$'…' near '"(printf %s $Z | string sub -l 4)"' (POSIX specifies \\\" \\' \\\\ \\a \\b \\e \\f \\n \\r \\t \\v \\cX \\xHH (1-2 digits) and \\ooo)"
        return 1
    end
    set -l 0fmt
    set -l 0arg # literal runs, printed through %s so that nothing in them is interpreted
    for 0p in (__dotenv_seq (count $K))
        set -l 0v $V[$0p]
        switch $K[$0p]
            case ''
                set -a 0fmt %s
                set -a 0arg $0v
            case \\
                switch $0v
                    case '0*' '1*' '2*' '3*' '4*' '5*' '6*' '7*'
                        set 0v (string pad -c 0 -w 3 -- $0v)
                        if string match -rq -- '\A[4-7]..' $0v
                            set 0err "\$'\\$V[$0p]' does not fit in a byte (unspecified)"
                            return 1
                        else if test $0v = 000
                            set 0err "\$'\\$V[$0p]' yields a NUL byte (unspecified)"
                            return 1
                        end
                        set -a 0fmt \\$0v
                    case \"
                        set -a 0fmt \\x22
                    case \'
                        set -a 0fmt \\x27
                    case \\
                        set -a 0fmt \\x5c
                    case a
                        set -a 0fmt \\x07
                    case b
                        set -a 0fmt \\x08
                    case e
                        set -a 0fmt \\x1b
                    case f
                        set -a 0fmt \\x0c
                    case n
                        set -a 0fmt \\x0a
                    case r
                        set -a 0fmt \\x0d
                    case t
                        set -a 0fmt \\x09
                    case v
                        set -a 0fmt \\x0b
                end
            case \\x
                set 0v (string pad -c 0 -w 2 -- $0v)
                if test $0v = 00
                    set 0err "\$'\\x$V[$0p]' yields a NUL byte (unspecified)"
                    return 1
                end
                set -a 0fmt \\x$0v
            case \\c
                set -l 0i (contains -i -- (string upper -- $0v) A B C D E F G H I J K L M N O P Q R S T U V W X Y Z '[' '\\\\' ']' '^' _)
                if set -q 0i[1]
                    set -a 0fmt \\x(printf %02x $0i)
                else if test "$0v" = '?'
                    set -a 0fmt \\x7f
                else
                    set 0err "\$'\\c$0v' is unspecified"
                    return 1
                end
        end
    end
    set 0res (printf (printf %s $0fmt | string collect -N -a) $0arg | string collect -N -a)
    return 0
end

# Diagnostics ---------------------------------------------------------------

function __dotenv_fail -a 0file 0line 0msg
    printf 'dotenv: %s:%s: %s\n' (__dotenv_vis $0file) $0line (__dotenv_vis $0msg) >&2
end

# $argv[1] with control characters shown as \xHH, so that text quoted from a
# file in a message cannot drive the terminal.
function __dotenv_vis -a 0t
    set -l P
    string match -raq -- '(?<P>[\x00-\x1f\x7f-\x9f]|[^\x00-\x1f\x7f-\x9f]++)' $0t
    for 0p in $P
        if string match -rq -- '\A[\x00-\x1f\x7f-\x9f]\z' $0p
            printf '\\\\x%02x' "'$0p"
        else
            printf %s $0p
        end
    end
    echo
end

# Line on which the word of item $argv[1] of the current file starts: match
# the items before it plus its leading blanks, and count their newlines.
function __dotenv_line -S -a 0i
    set -l P
    set -l 0unnamed (string replace -ra -- '\(\?<[a-z]>' '(?:' $0gap$0word | string collect)
    string match -rq -- $0def'\A(?<P>(?:'$0unnamed'){'(math $0i - 1)'}'(string replace -ra -- '\(\?<[a-z]>' '(?:' $0gap | string collect)')' $0text
    math (count (string split \n -- "$P")) - 1
end

function __dotenv_syntax -a 0t
    if string match -q -- '*$((*' $0t
        echo "arithmetic expansion is not supported: $0t"
    else if string match -q -- '*$(*' $0t; or string match -q -- '*`*' $0t
        echo "command substitution is not supported: $0t"
    else if string match -rq -- '\A[&|<>()]' $0t
        echo "shell operator '"(string sub -l 2 -- $0t)"' is not supported (only assignments, export, ';' and newlines are): $0t"
    else if string match -q -- ';*' $0t
        echo "unexpected ';': $0t"
    else if string match -q -- '*\\' $0t
        echo "backslash at end of input: $0t"
    else if string match -rq -- '[\x{A0}\x{1680}\x{180E}\x{2000}-\x{200A}\x{202F}\x{205F}\x{3000}]' $0t
        echo "unquoted non-ASCII space (shells disagree whether it separates words); quote it: $0t"
    else if string match -q -- "*\$'*" $0t
        echo "unterminated \$'…' or an escape in it that POSIX leaves unspecified (only \\\" \\' \\\\ \\a \\b \\e \\f \\n \\r \\t \\v \\cX \\xHH and \\ooo, not yielding NUL): $0t"
    else if string match -rq -- '[\x27"]' $0t
        echo "unterminated or unsupported quoting: $0t"
    else if string match -rq -- '\$[0-9@*#?$!-]' $0t
        echo "special parameters (\$1 \$@ \$\$ \$? …) are not supported: $0t"
    else if string match -q -- '*$*' $0t
        echo "unsupported use of '\$' (unspecified in POSIX): $0t"
    else
        echo "syntax error near: $0t"
    end
end

function __dotenv_badchar -a 0c
    switch $0c
        case '`*'
            echo "command substitution is not supported"
        case '"*'
            echo "a double quote inside \${…} within double quotes is unspecified"
        case '$*'
            echo "unsupported use of '\$' (unspecified in POSIX)"
        case '*'
            echo "unsupported character '$0c'"
    end
end

function __dotenv_cmderr -a 0kind 0text
    switch $0kind
        case D
            echo "command '--' is not supported"
        case '*'
            if test "$0text" = \r
                echo "stray carriage return: the file has CRLF line endings; convert it to LF"
            else if string match -q -- ﻿'*' $0text
                echo "the file starts with a byte order mark (U+FEFF); remove it"
            else if string match -q -- '*'\r $0text
                echo "command '$0text' is not supported (the line ends with a carriage return: CRLF line endings?)"
            else
                echo "command '$0text' is not supported (only assignments and export are)"
            end
    end
end

function __dotenv_help
    echo 'Usage: dotenv [-p|--print] [--] [FILE ...]

Assign and export the variables defined in POSIX shell assignment files
(default: ./.env) exactly as `set -a; . FILE` would in a POSIX shell.
FILE - reads standard input; several files act as if sourced in order.

  -p, --print  print the resulting `set -gx` commands instead of running them
  -h, --help   show this help

Accepted: NAME=value words, export [--] operands, comments, `;` and
newlines; quoting with \, \'...\', "..." and $\'...\'; the expansions
$NAME ${NAME} ${NAME-w} ${NAME:-w} ${NAME=w} ${NAME:=w} ${NAME?w}
${NAME:?w} ${NAME+w} ${NAME:+w} ${#NAME} ${NAME%w} ${NAME%%w} ${NAME#w}
${NAME##w}; tilde expansion. Command substitution, other commands, and
constructs whose meaning POSIX leaves unspecified are errors. Nothing is
assigned unless the whole input is accepted.'
end
