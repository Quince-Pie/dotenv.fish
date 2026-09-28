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
correct answer. The rules are applied to the whole file, including
expansions that are never evaluated, and before anything is assigned. A
POSIX shell may parse all of a sourced file before running it, so refusing
the whole file conforms too.

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
| `A=$HOSTNAME` when HOSTNAME is not exported | bash sets it on its own, the other shells do not |
| `A=${PRESET-$RANDOM}` | busybox exports RANDOM once it merely reads this |
| `A=${X-\}}` inside `"…${Y-"…\}…"}"` | `\}` there is an escape in dash, busybox and ksh93 only |
| `HOME=/h/` followed by `A=~/x` | `//x` in some shells, `/x` in others |
| `A=1\r` on a line of its own (CRLF file) | a command named CR; the message says to convert the file |

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
  in a file is always `<space><tab><newline>`. A bare `export IFS` exports
  that value, as the shells do.
* An exported global `argv` cannot be read from a function, so a file that
  refers to `argv` while one exists is refused.
* `dotenv` does not depend on the session's `IFS`, `fish_read_limit`
  aside: input above that limit is an error, not a truncation.

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

* `tests/cases`: 235 hand-written cases, all `ok`, `ok-err`, `ok-rej` or
  `ok-unsup` (`tests/mkcases.py`, then `tests/difftest.py tests/cases`).
* `tests/fuzz.py`: a grammar-based generator. It mixes valid constructs
  with near misses, and inserts line continuations and stray characters at
  random. The last four campaigns (21,000 files) found 0 MISMATCH and 0
  ACCEPT on the committed versions; the five ACCEPTs of the one before led
  to fixes. Campaign logs are kept in `.work/fuzz*.log`.
* `tests/specials.py`: 210 variable names that some shell sets or treats
  specially (from each shell's startup variables and manuals). Each is
  assigned (3 values), referred to while unset and while inherited
  (3 values), and exported bare: 1,680 cases, 0 unsound verdicts. The lists
  in `dotenv` are derived from its output.
* `tests/unit.fish`: 54 checks of what the oracle cannot see: scope,
  atomicity, messages and line numbers, options, standard input, `--print`
  round trips, fish-specific refusals, independence from `IFS`.

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
* bash: brace-expands `export` operands.
* yash: reads single quotes as quotes in a `${…}` nested in a double-quoted
  `${x-…}` word, and a tilde expansion as a pattern; rejects bytes ≥ 0x80
  in glibc's C locale. Such inputs are refused, or the case is marked.
* dash and busybox: expand a nested tilde in some never-evaluated words.

## Performance

Method: `bench/run.sh REPS` runs one fresh fish process per workload
(`bench/gen.py`) and calls each loader in batches of B calls, sized to take
about 60 ms, after a warm-up. It reports the median, minimum and maximum
per-call time over REPS batches. Machine: AMD Ryzen 9 9950X3D, `performance`
governor, benchmark process pinned to one core (`taskset -c 6`), desktop
otherwise idle (load ≈ 1.7 of 32 threads).

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

PERF_TABLE

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
grammar and skip the interpretation entirely.

Cost model: a fish statement costs ~1.5–3 µs, a command substitution
~10–17 µs, an external command ~0.5–1 ms. So the implementation avoids
forks altogether and uses builtins that handle whole lists per call. It
uses digit-prefixed local variables, which no POSIX name can collide with,
and O(1) lookups through per-name variables.

Alternatives that were considered and rejected:

* Delegating to `sh` (bass, replay.fish, foreign-env). It executes the
  file, so a `.env` becomes arbitrary code. It inherits whichever shell's
  deviations, and costs a fork and exec (≈3.5 ms) even for trivial files.
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
* Expansion-heavy files take about 0.2–0.4 ms per expansion. That is
  slower than sourcing them in dash, which is not exact.
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
fish --no-config unit.fish
cd ../bench && ./run.sh 9              # all loaders, all workloads
```
