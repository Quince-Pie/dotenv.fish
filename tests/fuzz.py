#!/usr/bin/env python3
"""Grammar-based differential fuzzing of dotenv against the POSIX shells.

Generates random .env files that mix valid constructs with near-misses,
runs each through difftest.verdict and reports soundness failures:
MISMATCH (dotenv's result differs from the shells) and ACCEPT (dotenv
accepted input the shells disagree on or reject). REJECT verdicts (dotenv
refused input all shells agree on) are counted and sampled for review.

usage: fuzz.py [N] [SEED] [WORKERS]
"""
import os, random, re, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import difftest  # noqa: E402

NAMES = ["A", "B", "C", "D1", "_u", "X_PATH", "PRESET", "EMPTY", "HOME", "UNSET_V", "LANG_X"]
REFS = NAMES + ["NOPE", "PWD"]
PLAIN = list("abcXYZ019_-+.,@%^=#!{}/:~*?[]") + ["é", "日", "\r"]
SQ_CHARS = list("ab \t\"$`\\#;&|<>(){}*?~:/=\n") + ["é"]
DQ_PIECES = ["a", "b", " ", "\t", "'", "#", ";", "&", "|", "<", ">", "(", ")", "~", ":", "/", "*", "\n",
             "\\$", "\\`", "\\\"", "\\\\", "\\n", "\\t", "\\\n", "\\a", "\\}", "é", "$ ", "$'"]
DSQ_PIECES = ["a", " ", "\"", "\\n", "\\t", "\\e", "\\a", "\\b", "\\f", "\\r", "\\v", "\\\\", "\\'", "\\\"",
              "\\x41", "\\x4", "\\x7e1", "\\xc3\\xa9", "\\101", "\\7", "\\0", "\\cA", "\\c[", "\\c?", "\\c@",
              "\\u00e9", "\\z", "%", "%s", "\\\n", "\n", "$", "é"]
OPS = ["", "-", ":-", "=", ":=", "?", ":?", "+", ":+", "#", "##", "%", "%%"]

def r(): return random.random()

def plain(rnd):
    return "".join(rnd.choice(PLAIN) for _ in range(rnd.randint(1, 4)))

def word(rnd, depth, ctx="u"):
    """A shell word (unquoted context) made of random pieces."""
    parts = []
    for _ in range(rnd.randint(0, 3 if depth == 0 else 2)):
        k = rnd.random()
        if k < 0.22:
            parts.append(plain(rnd))
        elif k < 0.32:
            parts.append("\\" + rnd.choice(list("ab $'\"\\#;~*n\n") + ["é"]))
        elif k < 0.45:
            parts.append("'" + "".join(rnd.choice(SQ_CHARS) for _ in range(rnd.randint(0, 4))) + "'")
        elif k < 0.60:
            parts.append('"' + dq(rnd, depth) + '"')
        elif k < 0.67:
            parts.append("$'" + "".join(rnd.choice(DSQ_PIECES) for _ in range(rnd.randint(0, 3))) + "'")
        elif k < 0.77:
            parts.append("$" + rnd.choice(REFS))
        elif k < 0.93 and depth < 2:
            parts.append(param(rnd, depth + 1))
        elif k < 0.96:
            parts.append(rnd.choice(["~", "~/x", "~root", ":~/y", "~" + rnd.choice(NAMES)]))
        else:
            parts.append(rnd.choice(["$", "$1", "$$", "$(x)", "`x`", "$((1))", "$@", "${#}", "$ "]))
    return "".join(parts)

def dq(rnd, depth):
    out = []
    for _ in range(rnd.randint(0, 4)):
        k = rnd.random()
        if k < 0.6:
            out.append(rnd.choice(DQ_PIECES))
        elif k < 0.8:
            out.append("$" + rnd.choice(REFS) + rnd.choice(["", "x", " "]))
        elif depth < 2:
            out.append(param(rnd, depth + 1, in_dq=True))
    return "".join(out)

def param(rnd, depth, in_dq=False):
    name = rnd.choice(REFS)
    op = rnd.choice(OPS)
    if op == "" and r() < 0.2:
        return "${#" + name + "}"
    if op == "":
        return "${" + name + "}"
    if op in ("#", "##", "%", "%%"):
        w = rnd.choice(["*", "?", "a*", "*e", "[a-z]", "[!e]*", "[[:space:]]*", "*[pqr]", "pre", "\"*\"",
                        "'pre'", "*/", "~", "\\*", "x" + word(rnd, depth)])
    else:
        w = dq(rnd, depth) if in_dq and r() < 0.6 else word(rnd, depth)
    return "${" + name + op + w + "}"

def assignment(rnd):
    return rnd.choice(NAMES) + "=" + word(rnd, 0)

def command(rnd):
    k = rnd.random()
    words = [assignment(rnd) for _ in range(rnd.randint(1, 3))]
    if k < 0.2:
        pre = words[:rnd.randint(0, 1)]
        ops = [assignment(rnd) if r() < 0.8 else rnd.choice(NAMES) for _ in range(rnd.randint(0, 2))]
        words = pre + ["export"] + (["--"] if r() < 0.1 else []) + ops
    sep = rnd.choice([" ", " ", "\t", " \\\n "])
    text = sep.join(words)
    if r() < 0.1:
        text += " # comment " + plain(rnd)
    return text

def document(rnd):
    lines = []
    if r() < 0.1:
        lines.append("# header")
    for _ in range(rnd.randint(1, 5)):
        c = command(rnd)
        if r() < 0.15:
            c += rnd.choice([";", " ;", "; " + command(rnd)])
        lines.append(c)
        if r() < 0.1:
            lines.append("")
    text = "\n".join(lines)
    if r() < 0.8:
        text += "\n"
    return text

def mutate(rnd, text):
    """Insert line continuations (and a few other characters) at random
    positions: a continuation is removed before tokenization, so it may land
    inside any token and must never change a result silently."""
    for _ in range(rnd.randint(1, 3)):
        i = rnd.randint(0, len(text))
        text = text[:i] + rnd.choice(["\\\n", "\\\n", "\\\n", "~", ":", "}", "{", "\\"]) + text[i:]
    return text

def run(seed_n):
    seed, n = seed_n
    rnd = random.Random(seed)
    text = document(rnd)
    if rnd.random() < 0.35:
        text = mutate(rnd, text)
    env = ""
    nonconf = set()
    if rnd.random() < 0.15:
        env = "# env: LC_ALL=C\n"
        if any(ord(ch) > 127 for ch in text):
            nonconf.add("yash")          # glibc's C locale rejects bytes >= 0x80
    if "$'" in text:
        # partial or non-conforming $'...' support (see cases/dsq_*.env)
        nonconf |= {"busybox", "zsh", "mksh"}
        if re.search(r"\\(x|[0-7])", text):
            nonconf |= {"dash", "yash"}   # encode \xHH bytes as characters
    if re.search(r"\$\{[A-Za-z_0-9]*:?=", text):
        nonconf.add("mksh")              # does not export ${x=word} under set -a
    if "${" in text and any(ord(ch) > 127 for ch in text) and "LC_ALL=C\n" not in env:
        nonconf.add("dash")              # dash 0.5.13: ${UNSET+é} yields é in UTF-8 locales
    if "export" in text:
        nonconf.add("zsh")               # expands export operands after prefix assignments
    if nonconf:
        env += "# nonconforming: " + ",".join(sorted(nonconf)) + "\n"
    fd, path = tempfile.mkstemp(suffix=".env", dir=WORK)
    with os.fdopen(fd, "wb") as f:
        f.write((env + text).encode())
    try:
        v, sh, fi, agree = difftest.verdict(path)
    except Exception as ex:  # a harness problem, not a dotenv verdict
        return ("HARNESS", path, str(ex), None, None)
    if v in ("ok", "ok-err", "ok-rej", "ok-unsup"):
        os.remove(path)
    return (v, path, text, sh, fi)

if __name__ == "__main__":
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    workers = int(sys.argv[3]) if len(sys.argv) > 3 else 8
    WORK = os.path.join(HERE, "fuzz-out")
    os.makedirs(WORK, exist_ok=True)
    counts = {}
    rejects = []
    with ThreadPoolExecutor(workers) as ex:
        for v, path, text, sh, fi in ex.map(run, [(seed * 100003 + i, i) for i in range(n)]):
            counts[v] = counts.get(v, 0) + 1
            if v in ("MISMATCH", "ACCEPT", "HARNESS"):
                print(f"[{v}] {path}\n{text!r}")
                if fi is not None:
                    print(f"    dotenv: {fi if fi[0] == 'err' else fi[1]}")
                    for s, res in (sh or {}).items():
                        print(f"    {s}: {res}")
            elif v == "REJECT":
                rejects.append((path, fi[1].splitlines()[-1] if fi[1] else ""))
    print("summary:", " ".join(f"{k}={c}" for k, c in sorted(counts.items())))
    reasons = {}
    for path, msg in rejects:
        key = msg.split(": ", 2)[-1][:70]
        reasons.setdefault(key, []).append(path)
    for key, paths in sorted(reasons.items(), key=lambda kv: -len(kv[1])):
        print(f"  REJECT x{len(paths)}: {key}  e.g. {paths[0]}")
