#!/usr/bin/env python3
"""Benchmark workloads (deterministic)."""
import os, random
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "work")
os.makedirs(D, exist_ok=True)
random.seed(42)

def simple_lines(n, prefix):
    out = ["# generated benchmark file", ""]
    for i in range(n):
        k = f"{prefix}_{i}"
        r = i % 6
        if r == 0: out.append(f"{k}=plain-value-{i}")
        elif r == 1: out.append(f'{k}="double quoted value {i}"')
        elif r == 2: out.append(f"{k}='single quoted $value {i}'")
        elif r == 3: out.append(f"export {k}=exported{i}")
        elif r == 4: out.append(f"{k}=value{i} # trailing comment")
        else: out.append(f"# section {i}\n{k}=https://example.com/api/v{i}?q=1")
    return "\n".join(out) + "\n"

def refs_lines(n, prefix, ratio):
    out = ["# with references", f"{prefix}_BASE=/srv/app"]
    for i in range(n):
        k = f"{prefix}_{i}"
        if random.random() < ratio:
            out.append(random.choice([
                f'{k}="${{{prefix}_BASE}}/data/{i}"',
                f"{k}=${prefix}_BASE/cache/{i}",
                f'{k}="${{{prefix}_MISSING:-default {i}}}"',
                f"{k}=${{HOME}}/.config/{i}",
            ]))
        else:
            out.append(f'{k}="literal value {i}"')
    return "\n".join(out) + "\n"

def heavy_lines(n, prefix):
    out = [f"{prefix}_BASE=/srv/app", f"{prefix}_URL=https://user:pw@db.example:5432/app"]
    for i in range(n):
        k = f"{prefix}_{i}"
        out.append(random.choice([
            f'{k}="${{{prefix}_BASE}}/$HOME/x\\"y\\" {i}"',
            f"{k}=${{{prefix}_UNSET:-a b}}:~/bin:${{{prefix}_BASE}}",
            f"{k}=$'tab\\there {i}\\n'",
            f"{k}=${{{prefix}_URL#*://}}",
            f"{k}=${{{prefix}_URL%%/*}}",
            f"{k}='single'\"double $USER\"plain\\ {i}",
        ]))
    return "\n".join(out) + "\n"

REALISTIC = r'''# Application
APP_NAME=my-service
APP_ENV=production
APP_DEBUG=false
APP_URL=https://my-service.example.com
APP_PORT=8080

# Database
DB_HOST=db.internal
DB_PORT=5432
DB_USER=service
DB_PASSWORD='p@ss$w0rd#!'
DB_NAME=service_prod
DATABASE_URL="postgres://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"

# Cache
REDIS_URL=redis://cache.internal:6379/0
CACHE_TTL=3600

# Mail
MAIL_FROM="My Service <noreply@example.com>"
SMTP_HOST=smtp.example.com
SMTP_PORT=587

# Paths
DATA_DIR=${HOME}/.local/share/my-service
LOG_DIR="${DATA_DIR}/logs"
export TOOLS_PATH="$HOME/.local/bin:$PATH"

# Keys
JWT_SECRET=5f4dcc3b5aa765d61d8327deb882cf99
PRIVATE_KEY="-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7
VJTUt9Us8cKjMzEfYyjiWA4R4/M2bS1GB4t7NXp98C3SC6dVMvDuictGeurT8jNbvJZHtCSuYEvuNMoSfm76oqFvAp8Gy0iz5sxjZmSnXyCdPEovGhLa0VzMaQ8s+CLOyS56YyCFGeJZ
-----END PRIVATE KEY-----"
FEATURE_FLAGS=search,billing,beta-ui
'''

FILES = {
    "small.env": simple_lines(20, "S"),
    "medium.env": simple_lines(100, "M"),
    "large.env": simple_lines(1000, "L"),
    "refs.env": refs_lines(100, "R", 0.2),
    "heavy.env": heavy_lines(100, "H"),
    "realistic.env": REALISTIC,
}
for name, text in FILES.items():
    with open(os.path.join(D, name), "w") as f:
        f.write(text)
print("\n".join(f"{n}: {len(t.splitlines())} lines" for n, t in FILES.items()))
