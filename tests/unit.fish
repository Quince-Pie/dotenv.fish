# Behavioural tests of dotenv that the differential tests cannot express:
# interface, diagnostics, atomicity, fish integration.
#   fish --no-config tests/unit.fish
source (status dirname)/../functions/dotenv.fish

set -g __pass 0
set -g __fail 0
function check -a name
    # usage: check NAME CONDITION...   (CONDITION is run as a command)
    if $argv[2..-1]
        set __pass (math $__pass + 1)
    else
        set __fail (math $__fail + 1)
        printf 'FAIL: %s\n' $name
    end
end
function check_not -a name
    if not $argv[2..-1]
        set __pass (math $__pass + 1)
    else
        set __fail (math $__fail + 1)
        printf 'FAIL: %s\n' $name
    end
end
function same -a name got want
    if test "$got" = "$want"
        set __pass (math $__pass + 1)
    else
        set __fail (math $__fail + 1)
        printf 'FAIL: %s\n  got:  %s\n  want: %s\n' $name (string escape -- "$got") (string escape -- "$want")
    end
end

set -l tmp (mktemp -d)
function w -a file
    printf %s $argv[2..-1] >$file
end

# --- basic assignment, scope and export -------------------------------------
w $tmp/a.env 'A1=one' \n 'export A2="two words"' \n "A3='x'\"y\"z" \n
dotenv $tmp/a.env
same 'plain value' "$A1" one
same 'quoted value' "$A2" 'two words'
same 'mixed quoting' "$A3" xyz
check 'global scope' set -q -g A1
check 'exported' set -q -x A2
same 'child process sees it' (env | string match 'A2=*') 'A2=two words'
function __scope_probe
    dotenv $argv[1]
end
w $tmp/b.env 'SCOPED=1' \n
__scope_probe $tmp/b.env
check 'set globally from inside a function' set -q -g SCOPED

# --- exact values ------------------------------------------------------------
w $tmp/c.env 'NL="line1' \n 'line2' \n '"' \n "EMPTY_V=" \n "SP='  lead and trail  '" \n 'BS=a\\\\b' \n
dotenv $tmp/c.env
same 'newlines kept, incl. trailing' "$NL" 'line1
line2
'
check 'empty value is one empty element' test (count $EMPTY_V) -eq 1 -a -z "$EMPTY_V"
same 'spaces kept' "$SP" '  lead and trail  '
same 'backslash escape' "$BS" 'a\\b'

# --- duplicates, order, references between files --------------------------
w $tmp/d1.env 'DUP=1' \n 'DUP=2' \n 'REF=$DUP' \n 'DUP=3' \n
w $tmp/d2.env 'FROM1="$REF-$DUP"' \n
dotenv $tmp/d1.env $tmp/d2.env
same 'last assignment wins' "$DUP" 3
same 'reference sees value at that point' "$REF" 2
same 'later file sees earlier file' "$FROM1" 2-3

# --- path variables ---------------------------------------------------------
w $tmp/p.env 'MY_PATH=/a::/b:' \n
dotenv $tmp/p.env
same 'path variable exported verbatim' (env | string match 'MY_PATH=*') 'MY_PATH=/a::/b:'
check 'path variable is a fish list' test (count $MY_PATH) -eq 4

# --- atomicity ----------------------------------------------------------------
set -e ATOM1 ATOM2
w $tmp/e.env 'ATOM1=set' \n 'ATOM2=$(date)' \n
dotenv $tmp/e.env 2>/dev/null
check 'error status' test $status -eq 1
check_not 'nothing assigned on error' set -q ATOM1
w $tmp/e2.env 'ATOM2=ok' \n
dotenv $tmp/e2.env $tmp/e.env 2>/dev/null
check_not 'atomic across files' set -q ATOM2

# --- diagnostics and line numbers ----------------------------------------------
w $tmp/l.env '# comment' \n \n 'OK=1' \n 'ML="a' \n 'b"' \n '  BAD=x y' \n
set -l msg (dotenv $tmp/l.env 2>&1)
check 'line number after multi-line value' string match -q -- "*l.env:6:*" "$msg"
check 'names the offending command' string match -q -- "*'y'*" "$msg"
w $tmp/l2.env 'A=1' \n 'B=${C:?is required}' \n
set msg (dotenv $tmp/l2.env 2>&1)
check '${C:?word} message' string match -q -- "*l2.env:2: C: is required" "$msg"
w $tmp/l3.env 'X=1 &' \n
set msg (dotenv $tmp/l3.env 2>&1)
check 'operator message' string match -q -- "*operator '&'*" "$msg"
printf 'A=\033[31mred\n' >$tmp/l4.env
printf 'B=$(x)\033[31m\n' >>$tmp/l4.env
set msg (dotenv $tmp/l4.env 2>&1)
check_not 'control characters escaped in messages' string match -q -- '*'\e'*' "$msg"
w $tmp/crlf.env 'A=1' \r\n \r\n
set msg (dotenv $tmp/crlf.env 2>&1)
check 'CRLF diagnosed' string match -q -- '*carriage return*' "$msg"

# --- files and options -----------------------------------------------------------
set msg (dotenv $tmp/nonexistent.env 2>&1)
check 'missing file' string match -q -- '*no such file*' "$msg"
set msg (dotenv $tmp 2>&1)
check 'directory' string match -q -- '*is a directory*' "$msg"
printf 'A=1\0B=2\n' >$tmp/nul.env
set msg (dotenv $tmp/nul.env 2>&1)
check 'NUL byte' string match -q -- '*NUL*' "$msg"
dotenv --bogus 2>/dev/null
check 'unknown option is status 2' test $status -eq 2
check 'help' string match -q -- 'Usage: dotenv*' (dotenv -h)[1]
printf 'FROM_STDIN=yes\n' | dotenv -
same 'stdin' "$FROM_STDIN" yes
begin
    cd $tmp
    printf 'DEFAULT_FILE=1\n' >.env
    dotenv
    same 'default ./.env' "$DEFAULT_FILE" 1
    cd -
end
w $tmp/empty.env ''
set -l got (printf 'kept\n' | begin
        dotenv $tmp/empty.env
        read -l line
        echo $line
    end)
same 'does not read stdin for an empty file' "$got" kept

# --- --print ---------------------------------------------------------------------
w $tmp/pr.env 'PA="a b"' \n "PB='it''s'" \n 'PC=$PA!' \n 'PD="x' \n 'y"' \n
set -e PA PB PC PD
set -l printed (dotenv -p $tmp/pr.env | string collect)
check_not '--print does not assign' set -q PA
printf %s\n $printed | source
same '--print output round-trips (1)' "$PA" 'a b'
same '--print output round-trips (2)' "$PB" its
same '--print output round-trips (3)' "$PC" 'a b!'
same '--print output round-trips (4)' "$PD" 'x
y'

# --- fish-specific refusals ----------------------------------------------------------
set msg (printf 'PWD=/x\n' | dotenv - 2>&1)
check 'read-only fish variable refused' string match -q -- '*read-only*' "$msg"
set msg (printf 'HOME=/h/\n' | dotenv - 2>&1)
check 'HOME canonicalization refused' string match -q -- '*would store HOME*' "$msg"
set msg (printf 'PATH=/bin::/usr/bin\n' | dotenv - 2>&1)
check 'empty PATH entry refused' string match -q -- '*would store PATH*' "$msg"
for 0nm in fish_user_paths CMD_DURATION dirprev last_pid fish_bind_mode
    set msg (printf '%s=/x\n' $0nm | dotenv - 2>&1)
    check "fish-maintained $0nm refused" string match -q -- '*read-only or special fish*' "$msg"
end
set msg (printf 'RANDOM=1\n' | dotenv - 2>&1)
check 'shell-maintained RANDOM refused' string match -q -- '*some shells maintain it*' "$msg"
set -e HOSTNAME
set msg (printf 'A=$HOSTNAME\n' | dotenv - 2>&1)
check 'HOSTNAME not in the environment refused' string match -q -- '*not in the environment*' "$msg"
printf 'export IFS\n' | dotenv -
same 'export IFS exports the default' "$IFS" ' '\t\n
set -gu IFS \n' '\t # (fish's own value, unexported)
# dotenv does not depend on the session's IFS (empty IFS stops fish from
# splitting command substitutions)
set -gx DOTENV_T1 'p q'
set -g IFS ''
printf 'IFS_A="x y"\nIFS_B=${IFS_A%% *}\nexport IFS_C=3 IFS_D=4\nIFS_E=${DOTENV_T1%% *}\n' | dotenv -
set -g IFS \n' '\t
same 'works with an empty IFS' "$IFS_B:$IFS_D:$IFS_E" x:4:p
set -g fish_read_limit 8
printf 'LIMIT_A=0123456789\n' | dotenv - 2>/dev/null
check 'stdin over $fish_read_limit is an error' test $status -eq 1
set -e fish_read_limit
check_not 'nothing assigned over the limit' set -q LIMIT_A
set -U __dotenv_universal_probe universal
printf '__dotenv_universal_probe=global\n' | dotenv -
same 'universal variable untouched' (set -S __dotenv_universal_probe | string match -r 'universal.*' | string match -q '*universal*'; and echo yes) yes
set -e -U __dotenv_universal_probe

# --- scale ---------------------------------------------------------------------------
for i in (seq 5000)
    echo "BIG_$i=value_$i"
end >$tmp/big.env
dotenv $tmp/big.env
same 'large file' "$BIG_4999" value_4999

command rm -rf $tmp
printf '%d passed, %d failed\n' $__pass $__fail
test $__fail -eq 0
