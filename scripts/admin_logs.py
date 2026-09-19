#!/usr/bin/env python3
"""Pure log-tail + secret-redaction + service-restart allowlists for the Logs tab.

Imported by admin-http.py. Kept as a separate importable module (like admin_map /
admin_status) so the two security-critical bits — path-traversal defence and
secret redaction — are unit-tested in test_admin_logs.py. Logs are shown in a
browser, so every line is redacted before it leaves the endpoint, and a source
name can never be turned into an arbitrary filesystem path.
"""
import os
import re
from pathlib import Path

# Fixed (non-UE5) services whose logs the SPA may tail. UE5 instances are dynamic
# (ue5-<Map>[-suffix]) and enumerated by globbing the logs dir at request time.
LOG_SOURCES_FIXED = (
    "postgres", "mq-admin", "mq-game", "text-router", "fls-stub",
    "mock-k8s", "director", "gateway", "admin-http",
    "scheduler", "welcome-scanner", "market-bot", "autoscaler",
)

# Services the panel may RESTART. Deliberately a SUBSET of the supervised set:
#   - excludes postgres + mq-* (data/broker layer — dependents cascade);
#   - excludes ue5-* (slow start + console.sh's 90s all-UE5-dead grace can recycle
#     the container, and a live map should be drained with a broadcast first).
# Those are restarted via a full server restart instead.
RESTARTABLE_SERVICES = (
    "admin-http", "scheduler", "welcome-scanner", "market-bot", "autoscaler",
    "mock-k8s", "director", "gateway", "text-router", "fls-stub",
)

# Strict shape for a UE5 instance log name: ue5-<Map> plus the suffixes the
# spawner appends — the pool slot (ue5-DeepDesert_1-p2) and, for travel
# partitions, the dimension (ue5-DeepDesert_1-dim1-p101).
#
# The suffix used to be missing from this pattern even though the comment
# claimed it, so every real instance log was rejected at tail time AND filtered
# out of list_sources. What remained was the 0-byte placeholder console.sh
# touches per always-warm map — an operator debugging a crash-looping Deep
# Desert opened the Logs tab and was shown an empty file (2026-09-19).
#
# Each segment stays [A-Za-z0-9_] with single hyphens between, so '.', '/' and
# '..' remain unrepresentable; resolve_log_path's basename and containment
# checks are the other two independent guards.
_UE5_RE = re.compile(r"^ue5-[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*$")

LOG_TAIL_DEFAULT = 200
LOG_TAIL_MAX = 2000


def valid_log_source(name: str) -> bool:
    """A source is tail-able iff it is a known fixed service or matches the strict
    ue5-<map> shape. Rejects empty, separators, dots, traversal by construction."""
    return name in LOG_SOURCES_FIXED or bool(_UE5_RE.match(name or ""))


def valid_restartable_service(name: str) -> bool:
    """Restartable allowlist. UE5/postgres/mq-* are intentionally NOT restartable."""
    return name in RESTARTABLE_SERVICES


def resolve_log_path(logs_dir: str, name: str):
    """Map a source name to <logs_dir>/<name>.log with three independent guards:
      1. allowlist / shape check (rejects '..', '/', etc.);
      2. basename equality (any residual path component -> reject);
      3. realpath containment under logs_dir.
    Returns a Path, or None (caller -> 400). A rejected name touches no fs path."""
    if not valid_log_source(name):
        return None
    if os.path.basename(name) != name:
        return None
    root = Path(logs_dir).resolve()
    candidate = (root / f"{name}.log").resolve()
    try:
        candidate.relative_to(root)
    except ValueError:
        return None
    return candidate


def tail_file(path, n):
    """Return (last n lines, exists). Reads only the tail by seeking from the end
    in chunks, so a multi-GB ue5 log never gets slurped whole. utf-8 lossy decode
    so a partial multibyte char at a chunk boundary can't raise."""
    p = Path(path)
    if not p.is_file():
        return [], False
    n = max(1, min(LOG_TAIL_MAX, int(n)))
    chunk = 64 * 1024
    data = b""
    with open(p, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        pos = fh.tell()
        while pos > 0 and data.count(b"\n") <= n:
            step = min(chunk, pos)
            pos -= step
            fh.seek(pos)
            data = fh.read(step) + data
    return data.decode("utf-8", "replace").splitlines()[-n:], True


def _size_of(path: Path) -> int:
    """Byte size, or 0 when the file is absent/unreadable (advisory display only)."""
    try:
        return path.stat().st_size
    except OSError:
        return 0


def list_sources(logs_dir: str):
    """Available sources: the fixed services + globbed ue5-* present on disk, each
    flagged with whether its log file exists yet and how big it is.

    The size matters for the UE5 entries: console.sh touches a 0-byte
    ue5-<Map>.log per always-warm map while the instance itself logs to
    ue5-<Map>-p<slot>.log, so both names are legitimately present and only the
    size tells them apart. Listing both and showing the size beats hiding one,
    which would only move the surprise."""
    root = Path(logs_dir)
    out = []
    for n in LOG_SOURCES_FIXED:
        p = root / f"{n}.log"
        out.append({"name": n, "exists": p.is_file(), "size": _size_of(p)})
    try:
        for f in sorted(root.glob("ue5-*.log")):
            if _UE5_RE.match(f.stem):
                out.append({"name": f.stem, "exists": True, "size": _size_of(f)})
    except OSError:
        pass
    return out


# --------------------------------------------------------------------------
# Redaction. Logs are an operator-only security boundary: scrub every secret
# that can reach a log line before returning it. Applied to EVERY source (a
# value that "should" only be in one log can be echoed elsewhere via shared
# lib.sh exports or stack traces). Over-redaction is acceptable; leaking is not.
# --------------------------------------------------------------------------
REDACTIONS = [
    # admin-ui generated/operator password line (prestart.sh)
    (re.compile(r'(?i)(admin-ui[^\n]*password[^:\n]*:\s*)\S+'), r'\1[REDACTED]'),
    # admin-publish DRY-RUN token + base64 envelope echoes
    (re.compile(r'(?im)^(\s*Token:\s*)\S+'), r'\1[REDACTED]'),
    (re.compile(r'(?im)^(\s*Outer base64:\s*)\S+'), r'\1[REDACTED]'),
    # JWTs anywhere (DUNE_JWT / ServiceAuthToken) — 3-part base64url eyJ...
    (re.compile(r'eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}'), '[REDACTED_JWT]'),
    # generic key=value / key: value secrets (named secrets incl. unknown-shaped)
    (re.compile(r'(?i)((?:service_?auth_?token|servercommandsauthtoken|rmq_http_token_auth_secret|'
                r'rmq_secret|auth_?token|session_?secret|client_?key|api_?key|steam_api_key|'
                r'password|passwd|secret|bearer|token)\s*[=:]\s*)("?)([^"\s&]+)\2'),
     r'\1\2[REDACTED]\2'),
    # JSON-quoted secret keys: "loginPassword":"x", "password":"x", "ServiceAuthToken":"x".
    # The Director/UE5 log [ServerState] as JSON, so the server JOIN PASSWORD leaks into
    # director.log / ue5-*.log; the key:value rule above only catches the unquoted form
    # (there's a " between the key and the colon here). Only keys ENDING in a secret word
    # match, so "tokenCount" / "connected_players" stay intact.
    (re.compile(r'(?i)("[a-z0-9_]*(?:password|passwd|secret|authtoken|token|apikey|clientkey)"\s*:\s*)"[^"]*"'),
     r'\1"[REDACTED]"'),
    # CLI-flag form: -DatabasePassword=…  --token …  -ini:...:ServiceAuthToken=…
    (re.compile(r'(?i)(-{1,2}[\w:\[\]]*(?:password|token|secret|key|auth)[\w:\[\]]*[= ])(?!\s)([^\s"]+)'),
     r'\1[REDACTED]'),
    # Authorization: Bearer/Basic headers (HTTP error dumps)
    (re.compile(r'(?i)(Authorization:\s*(?:Bearer|Basic)\s+)\S+'), r'\1[REDACTED]'),
    # Postgres password literal only in a connection assignment (not bare 'dune')
    (re.compile(r'(?i)((?:DatabasePassword|Database_password)\s*[=:]\s*)dune\b'), r'\1[REDACTED]'),
    # Pelican keys (pacc_ client, papp_ application)
    (re.compile(r'\b(pacc|papp)_[A-Za-z0-9]{8,}\b'), r'\1_[REDACTED]'),
    # AMP_TOKEN ServerId=<base64> (mock-k8s)
    (re.compile(r'(?i)(AMP_TOKEN\s*[=:]\s*|ServerId=)[^\s"]+'), r'\1[REDACTED]'),
    # postgres:// / amqp(s):// connection strings with creds
    (re.compile(r'(?i)\b((?:postgres(?:ql)?|amqps?)://[^:@/\s]+:)[^@/\s]+@'), r'\1[REDACTED]@'),
    # erlang cookie lines
    (re.compile(r'(?i)(erlang[._]?cookie[\s=:]+)\S+'), r'\1[REDACTED]'),
    # long base64 blobs (RMQ secret etc.) — value-targeted backstop, last so the
    # named patterns win first
    (re.compile(r'\b[A-Za-z0-9+/]{80,}={0,2}\b'), '[REDACTED_B64SECRET]'),
]


def redact(line: str) -> str:
    for pat, repl in REDACTIONS:
        line = pat.sub(repl, line)
    return line


def redact_lines(lines):
    return [redact(line) for line in lines]
