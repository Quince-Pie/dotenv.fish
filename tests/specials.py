#!/usr/bin/env python3
"""Find the variable names that the reference shells set or treat specially,
and check dotenv's handling of them.

For every candidate name (those each shell defines at startup, plus names
from the shells' manuals) the differential test runs eight cases: assigning
5, x or the empty string; referring to it while it is unset; referring to it
while the environment has it (three values); and `export NAME`. A name for
which the shells disagree must be refused by dotenv; the script prints the
classification that dotenv's lists 0shdyn/0shdef and its assignment check
are derived from, and every case where dotenv's verdict is unsound.

usage: specials.py [WORKERS]
"""
import json, os, re, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import difftest, shells  # noqa: E402

MANUAL = """ENV HOME IFS LANG LC_ALL LC_COLLATE LC_CTYPE LC_MESSAGES LC_NUMERIC LC_TIME LC_MONETARY LINENO NLSPATH PATH PPID
PS1 PS2 PS3 PS4 PS0 PWD OLDPWD CDPATH MAIL MAILCHECK MAILPATH HISTFILE HISTSIZE HISTFILESIZE HISTCMD HISTCONTROL HISTIGNORE
HISTTIMEFORMAT FCEDIT EDITOR VISUAL TMOUT TMPDIR OPTIND OPTARG OPTERR RANDOM SRANDOM SECONDS EPOCHSECONDS EPOCHREALTIME
BASH_MONOSECONDS BASHPID BASH BASH_VERSION BASH_VERSINFO BASH_ENV BASH_ARGV0 BASH_ARGC BASH_ARGV BASH_SOURCE BASH_LINENO
BASH_SUBSHELL BASH_COMMAND BASH_COMPAT BASH_XTRACEFD BASH_REMATCH BASH_CMDS BASH_ALIASES BASH_EXECUTION_STRING
BASH_LOADABLES_PATH BASH_TRAPSIG FUNCNAME FUNCNEST DIRSTACK PIPESTATUS GROUPS UID EUID GID EGID SHELLOPTS BASHOPTS HOSTNAME
HOSTTYPE MACHTYPE OSTYPE HOSTFILE SHELL SHLVL COLUMNS LINES REPLY MAPFILE COPROC COMP_WORDBREAKS COMP_CWORD COMP_KEY
COMP_POINT COMP_TYPE COMP_LINE COMP_WORDS COMPREPLY READLINE_LINE READLINE_POINT READLINE_MARK GLOBIGNORE GLOBSORT FIGNORE
EXECIGNORE IGNOREEOF INPUTRC PROMPT_COMMAND PROMPT_DIRTRIM TIMEFORMAT auto_resume histchars CHILD_MAX POSIXLY_CORRECT
TEXTDOMAIN TEXTDOMAINDIR KSH_VERSION KSH_MATCH PATHSEP PGRP USER_ID KSHUID KSHGID KSHEGID NLINES JOBMAX CSWIDTH HISTEDIT
SH_OPTIONS YASH_VERSION YASH_LOADPATH YASH_AFTER_CD ECHO_STYLE HANDLED COMMAND_NOT_FOUND_HANDLER HISTRMDUP PS1R PS1S PS2R
PS2S POST_PROMPT_COMMAND YASH_LE_TIMEOUT ZSH_VERSION ZSH_NAME ZSH_PATCHLEVEL ZSH_SUBSHELL ZSH_ARGZERO ZSH_EVAL_CONTEXT
ZSH_SCRIPT ZSH_EXECUTION_STRING ZDOTDIR HOST CPUTYPE VENDOR TTY TTYIDLE USERNAME ERRNO SAVEHIST LISTMAX LOGCHECK
KEYTIMEOUT WORDCHARS PROMPT PROMPT2 PROMPT3 PROMPT4 RPROMPT RPS1 SPROMPT TIMEFMT prompt NULLCMD READNULLCMD TMPPREFIX
HISTCHARS KEYBOARD_HACK TRY_BLOCK_ERROR TRY_BLOCK_INTERRUPT WATCH WATCHFMT MODULE_PATH module_path FPATH fpath MANPATH
manpath cdpath mailpath path psvar PSVAR watch pipestatus signals argv ARGC status options parameters commands aliases
functions builtins USER LOGNAME TERM TZ DISPLAY""".split()

MODES = {  # name -> (environment value or None, file text)
    "assign5": (None, "{n}=5\nA=${{{n}-unset}}\n"),
    "assignx": (None, "{n}=x\nA=${{{n}-unset}}\n"),
    "assignE": (None, "{n}=\nA=${{{n}-unset}}\n"),
    "ref":     (None, "A=${{{n}-unset}}\n"),
    "refenvS": ("fromenv", "A=${{{n}-unset}}\n"),
    "refenv7": ("7", "A=${{{n}-unset}}\n"),
    "refenvD": ("/", "A=${{{n}-unset}}\n"),
    "export":  (None, "export {n}\n"),
}
GOOD = {"ok", "ok-err", "ok-rej", "ok-unsup"}

def startup_names():
    env = shells.fish_env()
    names = set()
    for argv in shells.SHELLS.values():
        out = subprocess.run(argv + ["set", "sh"], env=env, capture_output=True, cwd="/",
                             stdin=subprocess.DEVNULL).stdout.decode("utf-8", "replace")
        names |= set(re.findall(r"(?m)^([A-Za-z_][A-Za-z0-9_]*)=", out))
    return names - {k.decode() for k in env}

def main(workers):
    work = tempfile.mkdtemp(prefix="dotenv-specials-")
    names = sorted(startup_names() | set(MANUAL))
    def one(job):
        n, m = job
        envv, text = MODES[m]
        p = os.path.join(work, f"{m}__{n}.env")
        with open(p, "w") as f:
            f.write((f"# env: {n}={envv}\n" if envv else "") + text.format(n=n))
        v, sh, fi, agree = difftest.verdict(p)
        return n, m, v, agree
    with ThreadPoolExecutor(workers) as ex:
        res = list(ex.map(one, [(n, m) for n in names for m in MODES]))
    t = {}
    for n, m, v, agree in res:
        t.setdefault(n, {})[m] = agree
    def diverge(n, ms):
        return any(not t[n][m] for m in ms)
    print("shells disagree on assigning:", " ".join(n for n in names if diverge(n, ["assign5", "assignx", "assignE"])))
    print("shells disagree on the inherited value of:", " ".join(n for n in names if diverge(n, ["refenvS", "refenv7", "refenvD"])))
    print("shells disagree on the value when unset of:", " ".join(n for n in names if diverge(n, ["ref"])))
    print("shells disagree on `export NAME` of:", " ".join(n for n in names if diverge(n, ["export"])))
    unsound = [(n, m, v) for n, m, v, _ in res if v in ("MISMATCH", "ACCEPT")]
    print(f"{len(names)} names, {len(res)} cases; unsound verdicts: {len(unsound)}")
    for n, m, v in unsound:
        print(f"  {v} {m} {n}")
    return 1 if unsound else 0

if __name__ == "__main__":
    sys.exit(main(int(sys.argv[1]) if len(sys.argv) > 1 else 6))
