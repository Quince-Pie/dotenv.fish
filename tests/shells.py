#!/usr/bin/env python3
"""Differential oracle: source a .env file in several POSIX shells (POSIX mode)
with `set -a` and report which environment variables changed.

Usage (CLI):  shells.py FILE [FILE...]      prints per-shell diffs + consensus
As a module:  run_all(path, extra_env) -> {shell: result}
A result is ("ok", {name: bytes_value}) or ("err", stderr_text).
"""
import os, subprocess, sys

BIN = os.environ.get("SHELLS_BIN", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin"))
ENV_BIN = subprocess.run(["sh", "-c", "command -v env"], capture_output=True, text=True).stdout.strip()

# name -> argv prefix (script passed as the -c argument)
SHELLS = {
    "dash":    [f"{BIN}/dash", "-c"],
    "bash":    [f"{BIN}/bash", "--posix", "-c"],
    "yash":    [f"{BIN}/yash", "-o", "posixlycorrect", "-c"],
    "busybox": [f"{BIN}/busybox", "sh", "-c"],
    "mksh":    [f"{BIN}/mksh", "-o", "posix", "-c"],
    "ksh93":   [f"{BIN}/ksh", "-c"],
    "zsh":     [f"{BIN}/zsh", "--emulate", "sh", "-c"],
}

SCRIPT = 'set -a; . "$1" || exit 97; exec "$2" -0'

def base_env(extra=None):
    e = {"HOME": "/home/tester", "PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8",
         "PWD": "/", "PRESET": "preset value", "EMPTY": ""}
    if extra:
        e.update(extra)
    return e

def parse_env0(out):
    d = {}
    for rec in out.split(b"\0"):
        if not rec:
            continue
        k, _, v = rec.partition(b"=")
        d[k.decode("utf-8", "surrogateescape")] = v
    return d

# variables shells set or mutate on their own; never part of the comparison
NOISE = {"SHLVL", "_", "PWD", "OLDPWD", "A__z", "SHELL", "PS1", "PS2", "PS4", "IFS",
         "OPTIND", "PPID", "LINENO", "ENV", "HISTFILE", "KSH_VERSION"}

def run_one(shell, path, extra=None, timeout=10):
    env = base_env(extra)
    argv = SHELLS[shell] + [SCRIPT, "sh", os.path.abspath(path), ENV_BIN]
    empty = os.path.join(os.path.dirname(os.path.abspath(path)), ".empty.env")
    if not os.path.exists(empty):
        open(empty, "w").close()
    try:
        p = subprocess.run(argv, env=env, capture_output=True, timeout=timeout, cwd="/", stdin=subprocess.DEVNULL)
        b = subprocess.run(SHELLS[shell] + [SCRIPT, "sh", empty, ENV_BIN], env=env,
                           capture_output=True, timeout=timeout, cwd="/", stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return ("err", "timeout")
    if p.returncode != 0 or p.stderr:
        return ("err", (p.stderr.decode("utf-8", "replace").strip() or f"exit {p.returncode}"))
    before, after = parse_env0(b.stdout), parse_env0(p.stdout)
    diff = {k: v for k, v in after.items() if k not in NOISE and before.get(k) != v}
    gone = [k for k in before if k not in after and k not in NOISE]
    for k in gone:
        diff[k] = None
    return ("ok", diff)

def run_all(path, extra=None, shells=None):
    return {s: run_one(s, path, extra) for s in (shells or SHELLS)}

def fmt(res):
    kind, d = res
    if kind == "err":
        return "ERROR: " + d.splitlines()[-1][:120] if d else "ERROR"
    return " ".join(f"{k}={v!r}" for k, v in sorted(d.items())) or "(no change)"

if __name__ == "__main__":
    for path in sys.argv[1:]:
        print(f"== {path}")
        rs = run_all(path)
        groups = {}
        for s, r in rs.items():
            groups.setdefault(fmt(r), []).append(s)
        for text, ss in groups.items():
            print(f"  [{','.join(ss)}] {text}")
