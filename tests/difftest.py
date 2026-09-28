#!/usr/bin/env python3
"""Differential test: dotenv (fish) against POSIX shells run as
`set -a; . FILE`.

For every case the shells give either an environment diff or an error.
Verdicts:
  ok        dotenv's diff equals the diff every conforming shell produced
  ok-err    every shell failed and so did dotenv
  ok-rej    shells disagree (or the case is marked unspecified) and dotenv
            rejected it
  REJECT    all shells agree but dotenv rejected it (must be justified)
  MISMATCH  dotenv produced a result different from the shells  -> bug
  ACCEPT    dotenv accepted a case the shells disagree on        -> bug
The per-case expectation can be pinned with a first-line comment
`# expect: reject` (spec says unspecified even if shells agree) or
`# expect: accept` (spec is explicit even if a shell deviates); a
`# nonconforming: shell,shell` line drops shells known to deviate.
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import shells  # noqa: E402

import shutil
FISH = os.environ.get("FISH") or shutil.which("fish")
DOTENV = os.path.join(HERE, "..", "functions", "dotenv.fish")
XDG = tempfile.mkdtemp(prefix="dotenv-xdg-")

FISH_SCRIPT = r'''
source $argv[1]
eval $argv[4]
dotenv $argv[2]; or exit 97
exec $argv[3] -0
'''

def run_fish(path, extra=None, setup="", timeout=20):
    env = shells.base_env(extra)
    env.update({"XDG_CONFIG_HOME": XDG, "XDG_DATA_HOME": XDG, "XDG_CACHE_HOME": XDG})
    empty = os.path.join(os.path.dirname(os.path.abspath(path)), ".empty.env")
    if not os.path.exists(empty):
        open(empty, "w").close()
    def go(p):
        return subprocess.run([FISH, "--no-config", "-c", FISH_SCRIPT, DOTENV, os.path.abspath(p), shells.ENV_BIN, setup],
                              env=env, capture_output=True, timeout=timeout, cwd="/", stdin=subprocess.DEVNULL)
    try:
        r = go(path)
        b = go(empty)
    except subprocess.TimeoutExpired:
        return ("err", "timeout")
    if r.returncode != 0:
        return ("err", r.stderr.decode("utf-8", "replace").strip() or f"exit {r.returncode}")
    before, after = shells.parse_env0(b.stdout), shells.parse_env0(r.stdout)
    noise = shells.NOISE | {"XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"}
    diff = {k: v for k, v in after.items() if k not in noise and before.get(k) != v}
    for k in before:
        if k not in after and k not in noise:
            diff[k] = None
    return ("ok", diff)

def directives(path):
    d = {"expect": None, "nonconforming": set(), "env": {}, "setup": ""}
    with open(path, "rb") as f:
        for line in f.read().split(b"\n")[:5]:
            line = line.decode("utf-8", "replace")
            if line.startswith("# expect:"):
                d["expect"] = line.split(":", 1)[1].strip()
            elif line.startswith("# nonconforming:"):
                d["nonconforming"] = {s.strip() for s in line.split(":", 1)[1].split(",") if s.strip()}
            elif line.startswith("# fish-setup:"):
                d["setup"] = line.split(":", 1)[1].strip()
            elif line.startswith("# env:"):
                k, _, v = line.split(":", 1)[1].strip().partition("=")
                d["env"][k] = v
    return d

# ksh 2020.0.0 (the only ksh93 in nixpkgs) is the abandoned "ksh2020" fork with
# known parser bugs; it is reported but does not vote.
ADVISORY = {"ksh93"}

def verdict(path):
    dv = directives(path)
    sh_all = shells.run_all(path, dv["env"])
    sh = {s: r for s, r in sh_all.items() if s not in dv["nonconforming"] and s not in ADVISORY}
    fi = run_fish(path, dv["env"], dv["setup"])
    results = {json.dumps(r[1] if r[0] == "ok" else "ERR", sort_keys=True, default=lambda b: b.decode("latin1")) for r in sh.values()}
    agree = len(results) == 1
    all_err = all(r[0] == "err" for r in sh.values())
    ref = next(iter(sh.values()))
    if dv["expect"] == "unsupported":
        v = "ok-unsup" if fi[0] == "err" else "ACCEPT"
    elif dv["expect"] == "reject" or (not agree):
        v = "ok-rej" if fi[0] == "err" else "ACCEPT"
    elif all_err:
        v = "ok-err" if fi[0] == "err" else "ACCEPT"
    elif fi[0] == "err":
        v = "REJECT"
    else:
        v = "ok" if fi[1] == ref[1] else "MISMATCH"
    return v, sh_all, fi, agree

def show(v):
    if v is None:
        return "-"
    return v.decode("utf-8", "backslashreplace")

def main(paths, verbose=False):
    counts = {}
    for p in paths:
        v, sh, fi, agree = verdict(p)
        counts[v] = counts.get(v, 0) + 1
        bad = v in ("MISMATCH", "ACCEPT", "REJECT")
        if bad or verbose:
            print(f"[{v}] {os.path.relpath(p)}")
            if fi[0] == "err":
                print(f"    dotenv: ERROR {fi[1].splitlines()[-1] if fi[1] else ''}")
            else:
                print(f"    dotenv: " + " ".join(f"{k}={show(x)!r}" for k, x in sorted(fi[1].items())))
            groups = {}
            for s, r in sh.items():
                groups.setdefault(shells.fmt(r), []).append(s)
            for text, ss in groups.items():
                print(f"    [{','.join(ss)}] {text}")
    print("summary:", " ".join(f"{k}={n}" for k, n in sorted(counts.items())))
    return 0 if not any(k in counts for k in ("MISMATCH", "ACCEPT")) else 1

if __name__ == "__main__":
    args = sys.argv[1:]
    verbose = "-v" in args
    args = [a for a in args if a != "-v"]
    files = []
    for a in args:
        if os.path.isdir(a):
            files += sorted(os.path.join(a, f) for f in os.listdir(a) if f.endswith(".env"))
        else:
            files.append(a)
    sys.exit(main(files, verbose))
