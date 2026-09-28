#!/usr/bin/env python3
"""Differential oracle: source a .env file in several POSIX shells (POSIX mode)
with `set -a` and report which environment variables changed.

Usage (CLI):  shells.py FILE [FILE...]      prints per-shell diffs + consensus
As a module:  run_all(path, extra_env) -> {shell: result}
A result is ("ok", {name: bytes_value}) or ("err", stderr_text).
"""
import os, shutil, subprocess, sys, tempfile, threading

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

# dotenv runs the POSIX `locale` utility to learn the shell's character set;
# the oracle's PATH must provide it (bin/locale, see bin/README)
def base_env(extra=None):
    e = {"HOME": "/home/tester", "PATH": "/usr/bin:/bin:" + os.path.abspath(BIN), "LC_ALL": "C.UTF-8",
         "PWD": "/", "PRESET": "preset value", "EMPTY": ""}
    if extra:
        e.update(extra)
    return e

FISH = os.environ.get("FISH") or shutil.which("fish")
_fish_env = {}
_fish_env_lock = threading.Lock()

def fish_env(extra=None, setup=""):
    """The environment that programs started by fish receive, as bytes,
    after the fish commands `setup` ran. The contract compares with a shell
    started from it: fish adds USER and sets PWD, and drops variables it
    cannot import (status, history …)."""
    key = (tuple(sorted((extra or {}).items())), setup)
    with _fish_env_lock:
        if key not in _fish_env:
            xdg = tempfile.mkdtemp(prefix="dotenv-xdg-")
            env = base_env(extra)
            env.update({"XDG_CONFIG_HOME": xdg, "XDG_DATA_HOME": xdg, "XDG_CACHE_HOME": xdg})
            out = subprocess.run([FISH, "--no-config", "-c", "eval $argv[2]; exec $argv[1] -0", ENV_BIN, setup], env=env, cwd="/",
                                 capture_output=True, stdin=subprocess.DEVNULL, check=True).stdout
            _fish_env[key] = {k.encode("utf-8", "surrogateescape"): v for k, v in parse_env0(out).items()}
        return _fish_env[key]

def parse_env0(out):
    d = {}
    for rec in out.split(b"\0"):
        if not rec:
            continue
        k, _, v = rec.partition(b"=")
        d[k.decode("utf-8", "surrogateescape")] = v
    return d

# variables shells set or mutate on their own; not compared unless the file
# mentions them (then e.g. a bare `export IFS` must be seen to export IFS)
NOISE = {"SHLVL", "_", "PWD", "OLDPWD", "A__z", "SHELL", "PS1", "PS2", "PS4", "IFS",
         "OPTIND", "PPID", "LINENO", "ENV", "HISTFILE", "KSH_VERSION"}

def noise_for(path):
    import re
    with open(path, "rb") as f:
        words = set(re.findall(rb"[A-Za-z_][A-Za-z0-9_]*", f.read()))
    return {n for n in NOISE if n.encode() not in words or n == "_"}

def run_one(shell, path, extra=None, timeout=10, setup=""):
    env = fish_env(extra, setup)
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
    # stderr that the shell also writes for an empty file comes from its
    # startup (e.g. a warning about a locale in the environment); bash's
    # warning that it cannot switch to an assigned locale changes nothing
    # else (the value is still assigned and exported)
    err = b"\n".join(l for l in p.stderr.split(b"\n") if b"warning: setlocale: " not in l).strip()
    if p.returncode != 0 or (err and p.stderr != b.stderr):
        return ("err", (p.stderr.decode("utf-8", "replace").strip() or f"exit {p.returncode}"))
    before, after = parse_env0(b.stdout), parse_env0(p.stdout)
    noise = noise_for(path)
    diff = {k: v for k, v in after.items() if k not in noise and before.get(k) != v}
    gone = [k for k in before if k not in after and k not in noise]
    for k in gone:
        diff[k] = None
    return ("ok", diff)

def run_all(path, extra=None, shells=None, setup=""):
    return {s: run_one(s, path, extra, setup=setup) for s in (shells or SHELLS)}

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
