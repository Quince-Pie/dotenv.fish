# dotenv.fish

`dotenv` loads POSIX shell `.env` files into [fish](https://fishshell.com).
The result is exactly what a POSIX shell gets from

```sh
set -a; . ./.env; set +a
```

or, when that is not certain, an error that names the line and the reason.
A file is never loaded "roughly": either every variable gets the value a
conforming shell would give it, or nothing is assigned at all.

```fish
dotenv                  # ./.env
dotenv base.env local.env   # in order, as if sourced one after the other
dotenv - <file          # standard input
dotenv -p .env          # print the equivalent `set -gx` commands instead
```

Exit status: 0 on success, 1 on any error (then no variable is changed),
2 for a usage error.

## Install

Copy `functions/dotenv.fish` to `~/.config/fish/functions/`. fish loads it
on first use. It needs no other program; it only runs the POSIX `locale`
utility in one rare case (character semantics of non-ASCII text, see below).
Developed and tested with fish 4.9.3.

## The contract

For an input file F, `dotenv F` makes the fish environment equal to the
environment that a shell conforming to POSIX.1-2024 (XCU chapter 2) would
have after `set -a; . F; set +a`, when that shell is started with fish's
exported environment. Every variable assigned by F is exported. This holds
for the subset of the shell language that `.env` files use:

* variable assignments, several per command: `A=1 B=2`
* `export` with assignment and name operands, optionally after `--`
* comments, blank lines, `;` and newlines, line continuations (`\`-newline)
* quoting: `\`, `'…'`, `"…"` and `$'…'` (POSIX 2024)
* parameter expansion: `$NAME`, `${NAME}`, `${#NAME}`, `${NAME-w}`,
  `${NAME:-w}`, `${NAME=w}`, `${NAME:=w}`, `${NAME?w}`, `${NAME:?w}`,
  `${NAME+w}`, `${NAME:+w}`, `${NAME%w}`, `${NAME%%w}`, `${NAME#w}`,
  `${NAME##w}`, nested in any way
* tilde expansion (`~`, `~/dir`, `~user`, and after `:` in assignments)
* pattern matching in `%` `%%` `#` `##`: `*`, `?`, bracket expressions with
  character classes, and ranges in the POSIX locale

Everything outside this subset is an error. So is every construct inside
it whose result POSIX leaves unspecified, and every construct on which
conforming shells give different results, because then there is no single
correct answer. Syntax is checked for the whole file, including words that
are never evaluated. Nothing is assigned before the whole file has been
processed. A POSIX shell may parse all of a sourced file before running
it, so refusing the whole file conforms too.

Examples of what is refused, and why:

| input | reason |
| --- | --- |
| `A=$(date)`, `` A=`date` ``, `A=$((1+1))` | not assignments: commands would run |
| `ls`, `unset A`, `A=1 && B=2`, `A=1 >f` | commands and operators other than assignment and `export` |
| `A=$1`, `A=$$`, `A=${#}` | special and positional parameters |
| `export` alone, `export -p` | output unspecified; options not supported |
| `A=$'\z'`, `A=$'\x123'`, `A=$'\0'` | escapes that POSIX 2024 leaves unspecified |
| `A=${B:1}`, `A=${B/x/y}`, `A=${!B}` (even if never evaluated) | not POSIX forms; yash and ksh93 reject them when parsing |
| `A="${B-"x"}"` | a `"` inside `${…}` within `"…"` is unspecified (2.2.3) |
| `A=${B%[a-z]}` in a UTF-8 locale | ranges are unspecified outside the POSIX locale |
| `A=~nosuchuser/x` | tilde expansion of an unknown login is unspecified |
| `LINENO=5`, `RANDOM=1`, `A=$SHLVL`, `A=$UID` | shells maintain these names themselves, differently |
| `A=$HOSTNAME` when HOSTNAME is not exported | bash and busybox set it themselves, the other shells do not |
| `A=${PRESET-$RANDOM}` | busybox exports RANDOM once it merely reads this |
| `A=${UNSET-"a\}b"}` | `\}` in `"…"` inside `${…}` is an escape in dash, busybox and ksh93 only |
| `A=x\:~/y` | zsh expands a tilde after an escaped colon, the others do not |
| `A=${V#@(p)}`, `A=${V%%|*}` | mksh and ksh read `(`, `|` and `)` in a pattern as an extended pattern (quoted, they work) |
| `A=${X:-<(x)}`, `A="${X:-<(}"` | bash reads a process substitution there, and runs it |
| `A=~/x` with `HOME=/h/` in the environment | `//x` in some shells, `/x` in others |
| a blank line in a file with CRLF line endings | a command named CR (the message says to convert the file; otherwise values keep a trailing CR, as in a shell) |

Messages look like `dotenv: app.env:12: $SHLVL is set or maintained by the
shell itself, …`. Text quoted from the file is shown with control
characters escaped, so a file cannot drive the terminal through an error
message.

## fish specifics

* Variables are set as globals and exported (`set -gx`), wherever
  `dotenv` is called from. A local variable of the same name in the calling
  function shadows the global there. Universal variables are not changed;
  the new global shadows a universal of the same name in this session.
* Values are exact, including newlines, trailing newlines, empty values,
  and bytes that are not UTF-8 (fish keeps those as U+F600…U+F6FF and
  exports the original bytes).
* Names ending in `PATH` are path variables in fish: a list split at `:`.
  The exported value is the same string, empty entries included.
* fish rewrites a few values when they are assigned. It canonicalizes
  `HOME`, and turns empty entries of `PATH` and `CDPATH` into `.`. If it
  would store a value of these other than the file's, `dotenv` refuses the
  file.
* fish's read-only variables are refused (`PWD`, `SHLVL`, `_`, `status`,
  `version`, …). So are `umask` and the variables fish changes on its own
  later in the session: `CMD_DURATION`, `dirprev`, `dirnext`, `last_pid`,
  `fish_bind_mode`, and `fish_user_paths`, which rewrites `PATH` as soon as
  it is set.
* Variables that fish itself reacts to still get exactly the file's value,
  and fish reacts to them. Examples are `LANG`, `LC_*`, `TERM`, `IFS` (for
  `read`) and `fish_*` settings such as `fish_trace` or
  `fish_function_path`.
* `IFS` is not read from the environment (POSIX shells reset it), so `$IFS`
  in a file is `<space><tab><newline>` unless the file assigns it. A bare
  `export IFS` exports that value, as the shells do.
* An exported global `argv` cannot be read from a function, so a file that
  refers to `argv` while one exists is refused.
* `dotenv` works whatever the session's `IFS` is. Input larger than
  `$fish_read_limit` is an error, not a truncation.

## Character semantics

`${#NAME}`, `?` and bracket expressions count characters. For non-ASCII
text that depends on the locale the shell starts with. `dotenv` supports
the case that is unambiguous: valid UTF-8 text, and a locale that is really
UTF-8. It checks the locale with `locale charmap`, run with the same
environment, because a locale that is named but not installed leaves a
shell in the C locale, counting bytes. If that check fails, or if the file
assigns `LANG` or `LC_*` (whether that changes the running shell's locale
differs between shells), such operations are refused. Byte-oriented shells
(mksh, busybox) disagree with the others here anyway.

## How it was verified

The reference is the seven POSIX shells available in nixpkgs, each run in
its POSIX mode:

| shell | version | mode |
| --- | --- | --- |
| dash | 0.5.13.3 | |
| bash | 5.3p9 | `--posix` |
| yash | 2.61 | `-o posixlycorrect` |
| busybox sh | 1.37.0 | |
| mksh | R59c | `-o posix` |
| zsh | 5.9.1 | `--emulate sh` |
| ksh | 2020.0.0 | advisory only: the abandoned ksh2020 fork has parser bugs |

`tests/difftest.py` is the oracle. It starts every shell from the
environment that fish exports (fish adds `USER`, drops `status`, …), after
any fish setup a case asks for. It runs `set -a; . FILE`, and compares the
changed environment with what `dotenv` produced in fish. Anything on stderr
counts as a shell error, except output the shell also prints for an empty
file. Verdicts:

* `ok`: dotenv's environment is identical to that of every voting shell.
* `ok-err`: every shell failed, and so did dotenv.
* `ok-rej`: the shells disagree, or the case is marked unspecified, and
  dotenv refused it.
* `ok-unsup`: a case marked as outside the supported subset, refused.
* `REJECT`: all shells agree, but dotenv refused. This is allowed only as a
  documented limitation.
* `MISMATCH`: a different result. This is a bug.
* `ACCEPT`: accepted although the shells disagree. This is also a bug.

A case can mark a shell as `nonconforming` when that shell is known to
deviate. See the list below; each deviation has a case of its own.

Evidence for the final version:

* `tests/cases`: 260 hand-written cases, all `ok`, `ok-err`, `ok-rej` or
  `ok-unsup` (125, 19, 85 and 32; `tests/mkcases.py`, then
  `tests/difftest.py tests/cases`).
* `tests/fuzz.py`: a grammar-based generator. It mixes valid constructs
  with near misses, and inserts line continuations and stray characters at
  random. Every campaign ran against the version committed at the time.
  Every finding was fixed (or, for a shell's deviation, annotated), and the
  next campaign ran on the fixed version (table below).
* `tests/specials.py`: 210 variable names that some shell sets or treats
  specially (from each shell's startup variables and manuals). Each is
  assigned (3 values), referred to while unset and while inherited
  (3 values), and exported bare: 1,680 cases, 0 unsound verdicts. The lists
  in `dotenv` are derived from its output.
* `tests/unit.fish`: 54 checks of what the oracle cannot see: scope,
  atomicity, messages and line numbers, options, standard input, `--print`
  round trips, fish-specific refusals, independence from `IFS`.

| campaign | files | MISMATCH | ACCEPT | what the findings were |
| --- | ---: | ---: | ---: | --- |
| 1 | 1,500 | 0 | 12 | reference-shell deviations (now annotated or refused) |
| 2 | 2,500 | 0 | 2 | dash and yash on `$'…'` inside `${…}` words (refused since) |
| 3 | 2,500 | 0 | 1 | yash on quotes in a nested `${…}` within `"…"` (refused since) |
| 4 | 3,000 | 1 | 4 | `$NAME\`-newline-letter lengthened the name; `\}` in `"…"` in `${…}` |
| 5 | 3,000 | 1 | 0 | `%\`-newline-`%` read as `%` instead of `%%` |
| 6 | 4,000 | 0 | 5 | non-POSIX `${…}` forms in unevaluated words; quotes in nested `${…}` |
| 7 | 4,000 | 0 | 0 | |
| 8 | 5,000 | 0 | 5 | busybox exports RANDOM on reading `$RANDOM`; yash and tilde in patterns |
| 9 | 5,000 | 0 | 0 | |
| 10 | 5,000 | 0 | 0 | |
| 11 | 6,000 | 0 | 1 | zsh expands `~` after `\:` |
| 12 | 8,000 | 0 | 0 | |
| 13 | 8,000 | 0 | 1 | bash runs `<(…)` inside `${…}` as a process substitution |
| 14 | 8,000 | 0 | 0 | |
| 15 | 8,000 | 0 | 0 | final version |

Deviations of the reference shells that the tests account for:

* dash 0.5.13: `${UNSET+é}` yields `é` wrongly in UTF-8 locales; its
  `$'\xHH'` and `$'\ooo'` bytes are encoded as characters (yash too).
* busybox: partial `$'…'` (no `\e`, no `\cX`); byte-oriented patterns and
  lengths (mksh too); exports RANDOM/EPOCHSECONDS/EPOCHREALTIME after merely
  parsing an expansion of them (such files are refused).
* mksh: does not export `${x=w}` assignments under `set -a`; reads `$'` in
  `"…"` as a quote.
* zsh (sh emulation) and ksh2020: expand `export` operands after the
  command's prefix assignments. zsh also has no `$'\cX'`.
* bash: brace-expands `export` operands; takes an unquoted `<(` or `>(`
  inside `${…}` as a process substitution (such files are refused).
* yash: reads single quotes as quotes in a `${…}` nested in a double-quoted
  `${x-…}` word, and a tilde expansion as a pattern; rejects bytes ≥ 0x80
  in glibc's C locale. Such inputs are refused, or the case is marked.
* dash and busybox: expand a nested tilde in some never-evaluated words.
* mksh and ksh93: extended patterns (`@(…)`, `*(…)`, `a|b`) even in POSIX
  mode (refused); zsh: a tilde after `\:` (refused).

## Performance

Method: `bench/run.sh REPS` runs one fresh fish process per workload
(`bench/gen.py`) and calls each loader in batches of B calls, sized to take
about 60 ms, after a warm-up. It reports the median, minimum and maximum
per-call time over REPS batches (REPS = 9 here). Machine: AMD Ryzen 9
9950X3D (32 threads), Linux 6.18, `performance` governor. The benchmark
process was pinned to one core (`taskset -c 6`) on a desktop with a browser
open (load average 3.7–4.0 during the run). fish 4.9.3, dash 0.5.13.3,
bash 5.3p9.

Loaders compared:

* `dotenv`: this project.
* `dash` / `bash`: the conventional control. Source the file in that shell
  and import the changed variables (the mechanism of bass, replay.fish and
  foreign-env, reduced to its fastest form). This runs the file as code and
  inherits the shell's bugs (e.g. dash's multibyte bug), so it is not a
  safe or exact alternative.
* `naive`: the line-splitting loop of most fish dotenv plugins. It is fast
  but wrong for quoting, escapes, expansions, multi-line values and `#`
  inside values.

| workload | dotenv | dash | bash | naive | dotenv vs dash |
| --- | ---: | ---: | ---: | ---: | ---: |
| small: 20 literal assignments | 313 µs | 3.25 ms | 4.08 ms | 1.21 ms | 10.4× faster |
| medium: 100 literal assignments | 567 µs | 4.50 ms | 5.45 ms | 5.91 ms | 7.9× faster |
| large: 1000 literal assignments | 4.79 ms | 18.93 ms | 23.63 ms | 58.75 ms | 4.0× faster |
| refs: 100 values, 20% with `$X`/`${X}`/`${X:-d}` | 4.05 ms | 4.62 ms | 5.54 ms | 5.75 ms | 1.1× faster |
| heavy: 100 values, all expansions, patterns, `$'…'`, escapes | 32.62 ms | 4.61 ms | 5.58 ms | 5.81 ms | 7.1× slower |
| realistic: a typical application `.env` (36 lines) | 1.58 ms | 3.30 ms | 4.20 ms | 1.53 ms | 2.1× faster |

Median per call over 9 batches; the largest max/min ratio of any cell is 1.065.

Cost per construct (`bench/micro.fish`, median of 5 batches of 60 calls):

| construct (20 per file) | per file | per value beyond a literal |
| --- | ---: | ---: |
| `V="literal value"` | 306 µs |  |
| `V="${BASE}/data/0"` | 2470 µs | 108 µs |
| `V=$BASE/x/0` | 2458 µs | 108 µs |
| `V="${MISSING:-default 0}"` | 2883 µs | 129 µs |
| `V=${MISSING:-d0}` | 2862 µs | 128 µs |
| `V=~/x/0` | 3116 µs | 141 µs |
| `V="a\"b\"0"` | 2248 µs | 97 µs |
| `V=$'tab\there'` | 4598 µs | 215 µs |
| `V=${URL#*://}` | 3605 µs | 165 µs |

The tables show calls in a warm session. Once per session, fish parses
the function file when `dotenv` is first used: 1.3 ms. Measured with
hyperfine over 200 runs, `fish -c 'source functions/dotenv.fish'` takes
2.11 ms against 0.77 ms for `fish -c true`. The first call then takes
1.8 ms for `realistic.env` (3.95 ms in total).

In short, dotenv is the fastest of the measured loaders on files made
mostly of literal assignments, 4–10× faster than letting dash source them.
On the realistic file it is 2.1× faster than dash, and within 4% of the
naive loop, which gets such files wrong. On files made of expansions only
(`heavy`), it is about 7× slower than dash: each expansion is interpreted
in fish script, since the file is never executed.

## Design

Data flow for one file: the file is read with one `string split0` (NUL
bytes are detected, not dropped). It is then tokenized by one PCRE2 regex,
a recursive grammar of the covered shell subset (`(?(DEFINE)…)`), into
aligned lists: separator, `export` prefix, name, literal value, raw value,
other word, error. A second pass of the same regex turns the file into a
one-letter-per-item signature. From it, the commands that need
interpretation are found with two more regex matches. Runs of literal
assignments between them are appended in bulk, and only the remaining
commands are interpreted, word by word, in POSIX order (2.9.1). Finally
all variables are assigned by a single `read` that splits on a delimiter
absent from every value. Files with only literal assignments use a smaller
grammar and skip the interpretation entirely. Within the interpretation,
the common word shapes have fast paths of one regex match each. These are
interpolation (`"${A}/x"`), defaults (`${A:-x}`), patterns made of literal
text and `*` (`${URL#*://}`), and `"…"` with backslash escapes. Every other
word goes through a general interpreter, piece by piece. Both give the same
results; the corpus and the fuzzer exercise both.

Cost model: a fish statement costs ~1.5–3 µs, a command substitution
~10–17 µs, an external command ~0.5–1 ms. So the implementation avoids
forks altogether and uses builtins that handle whole lists per call. It
uses digit-prefixed local variables, which no POSIX name can collide with,
and O(1) lookups through per-name variables.

Alternatives that were considered and rejected:

* Delegating to `sh` (bass, replay.fish, foreign-env). It executes the
  file, so a `.env` becomes arbitrary code. It inherits whichever shell's
  deviations, and costs a fork and exec (≈3.2 ms here) even for trivial
  files.
* Translating to fish code and `eval`-ing it. The same risk as delegation
  wherever the escaping is imperfect.
* Line-oriented parsing, as in most fish plugins and many dotenv libraries
  (python-dotenv, compose-go, direnv's dotenv). These are different
  languages: quotes, escapes, `#` and expansions differ from the shell's.
  The survey found every fish implementation wrong for POSIX files.
  The closest in spirit, shdotenv (awk), changes the meaning in places (it
  keeps existing environment values by default and rejects duplicates).

## Limitations

* Only the subset above: no `$(…)`, `$((…))`, positional or special
  parameters, `readonly`, `unset`, `set`, `.`, functions or control flow.
* Some rare constructs that all shells agree on are still refused as
  unsupported, e.g. a line continuation inside a `${…}` name or operator,
  quoting inside a `${…}` nested in a double-quoted `${x-…}` word, `$OPTIND`
  (always 1), and character semantics outside UTF-8 locales.
* The list of names that shells maintain themselves comes from the shell
  versions above. Other shells or versions may maintain more names.
* On standard input, a NUL byte that is the very last byte cannot be told
  apart from the end of the input.
* Each expansion costs about 0.1–0.2 ms (table above). On files made
  mostly of expansions, that is slower than sourcing them in dash, which is
  neither exact nor safe.
* Verified on Linux (glibc) with fish 4.9.3 only.

## Repository

```
functions/dotenv.fish  the deliverable (install this file)
tests/shells.py        oracle: runs the reference shells
tests/difftest.py      differential test runner (verdicts above)
tests/mkcases.py       the corpus (writes tests/cases/*.env)
tests/fuzz.py          grammar-based differential fuzzer
tests/specials.py      shell-maintained variable names
tests/unit.fish        behavioural tests of the fish side
bench/                 workloads, loaders, runner and micro-benchmarks
```

The tests expect the shells, `python3`, `hyperfine` and `locale` as
symlinks in `bin/` (for example from nixpkgs). Then:

```sh
cd tests && ../bin/python3 mkcases.py && ../bin/python3 difftest.py cases
../bin/python3 fuzz.py 2000 1 8        # N SEED WORKERS
../bin/python3 specials.py 8
# (unit.fish sets and erases a universal variable: use a scratch config dir)
env XDG_CONFIG_HOME=$(mktemp -d) XDG_DATA_HOME=$(mktemp -d) fish --no-config unit.fish
cd ../bench && ../bin/python3 gen.py && taskset -c 6 ./run.sh 9   # all loaders, all workloads
```
