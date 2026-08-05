#!/usr/bin/env python3
"""Render Claude Code transcripts for the sessions the screenshot pointed at.

snap-extract.sh resolves tmux session names to working directories; this turns
each of those directories into the conversation that happened in it. Reads a
manifest on disk, writes the bundle to stdout, and writes the sessions it could
not resolve to $SNAP_MISSES so the caller can try its scrollback fallback.

Everything is driven by SNAP_* environment variables, which map one-to-one onto
the script's flags. No arguments.
"""

import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

# ── options ────────────────────────────────────────────────────────────────
MANIFEST = os.environ["SNAP_MANIFEST"]
MISSES = os.environ["SNAP_MISSES"]
STORES = [s for s in os.environ.get("SNAP_STORES", "").splitlines() if s]
TURNS = int(os.environ.get("SNAP_TURNS") or 0)
TOOLS = os.environ.get("SNAP_TOOLS") or "summary"
THINKING = os.environ.get("SNAP_THINKING") == "1"
SIDECHAINS = os.environ.get("SNAP_SIDECHAINS") == "1"
SINCE = os.environ.get("SNAP_SINCE") or ""
FORMAT = os.environ.get("SNAP_FORMAT") or "markdown"
MAXBYTES = int(os.environ.get("SNAP_MAXBYTES") or 0)
ALL_TRANSCRIPTS = os.environ.get("SNAP_ALL_TRANSCRIPTS") == "1"
LIST_ONLY = os.environ.get("SNAP_LIST") == "1"
DEBUG = os.environ.get("SNAP_DEBUG") == "1"
NOREDACT = os.environ.get("SNAP_NOREDACT") == "1"
EXTRA_REDACT = [p for p in (os.environ.get("SNAP_REDACT") or "").split(",") if p.strip()]

if TOOLS not in ("full", "summary", "none"):
    sys.exit("snap-extract: --tools must be full, summary, or none")
if FORMAT not in ("markdown", "xml", "json"):
    sys.exit("snap-extract: --format must be markdown, xml, or json")


def log(msg):
    if DEBUG:
        print(f"[snap-extract] {msg}", file=sys.stderr)


# ── redaction ──────────────────────────────────────────────────────────────
# A transcript is a recording of someone working on their own machine, so it
# routinely contains things that should not be pasted into a browser tab. These
# are masked by default; --no-redact turns them off deliberately.
BUILTIN_REDACTIONS = [
    (re.compile(r"sk-ant-[A-Za-z0-9_\-]{16,}"), "sk-ant-<redacted>"),
    (re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{16,}\b"), "<redacted-github-token>"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "<redacted-aws-key>"),
    (re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}\b"), "<redacted-slack-token>"),
    (re.compile(r"\bey[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"), "<redacted-jwt>"),
    (re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._\-]{16,}"), "Bearer <redacted>"),
    (re.compile(
        r"(?im)^(\s*(?:export\s+)?[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|ACCESS_?KEY)[A-Z0-9_]*\s*[:=]\s*)"
        r"['\"]?[^\s'\"]{6,}"), r"\1<redacted>"),
    (re.compile(r"(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"),
     "<redacted-private-key>"),
]
REDACTIONS = [] if NOREDACT else list(BUILTIN_REDACTIONS)
for pat in EXTRA_REDACT:
    try:
        REDACTIONS.append((re.compile(pat.strip()), "<redacted>"))
    except re.error as exc:
        sys.exit(f"snap-extract: bad --redact pattern {pat.strip()!r}: {exc}")


def scrub(text):
    if not text:
        return text
    for pattern, replacement in REDACTIONS:
        text = pattern.sub(replacement, text)
    return text


# ── time filter ────────────────────────────────────────────────────────────
def parse_since(spec):
    if not spec:
        return None
    m = re.fullmatch(r"(\d+)\s*([smhdw]?)", spec.strip(), re.I)
    if not m:
        sys.exit(f"snap-extract: bad --since {spec!r} — use forms like 30m, 6h, 3d")
    n, unit = int(m.group(1)), (m.group(2) or "h").lower()
    seconds = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}[unit]
    return datetime.now(timezone.utc) - timedelta(seconds=n * seconds)


CUTOFF = parse_since(SINCE)


def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


# ── locating transcripts ───────────────────────────────────────────────────
def slugify(path):
    """Claude Code files a project under its cwd with every separator flattened.

    /data/agentic-os/x/.worktrees/y -> -data-agentic-os-x--worktrees-y
    The mapping is lossy, so it is only ever used forwards: cwd -> slug. The
    real cwd is read back out of the transcript itself.
    """
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def transcripts_for(cwd, store_dir):
    dirs = [store_dir] if store_dir else [os.path.join(s, slugify(cwd)) for s in STORES]
    found = []
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for name in os.listdir(d):
            if name.endswith(".jsonl"):
                p = os.path.join(d, name)
                try:
                    found.append((os.path.getmtime(p), p))
                except OSError:
                    pass
    found.sort(reverse=True)
    paths = [p for _, p in found]
    return paths if ALL_TRANSCRIPTS else paths[:1]


# ── message extraction ─────────────────────────────────────────────────────
def truncate(text, limit):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[:limit] + " …"


def summarize_tool_input(name, payload):
    """One line that says what the call actually did.

    Whole-payload JSON is unreadable at a glance and enormous in aggregate, so
    prefer the field that carries the intent and fall back to compact JSON.
    """
    if not isinstance(payload, dict):
        return truncate(payload, 200)
    for key in ("command", "file_path", "pattern", "path", "prompt", "query", "url", "description"):
        if payload.get(key):
            return truncate(payload[key], 200)
    return truncate(json.dumps(payload, ensure_ascii=False), 200)


def block_text(block):
    """A tool_result's content is sometimes a string, sometimes blocks."""
    content = block.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for sub in content:
            if isinstance(sub, dict) and sub.get("type") == "text":
                parts.append(sub.get("text", ""))
            elif isinstance(sub, dict) and sub.get("type") == "image":
                parts.append("<image>")
        return "\n".join(parts)
    return ""


def render_message(record):
    """A transcript record -> (role, timestamp, text), or None if it is empty.

    Returning None for empties matters: with --tools none, a record that held
    nothing but a tool call would otherwise become a blank turn and eat one of
    the --turns slots.
    """
    role = record["type"]
    message = record.get("message") or {}
    content = message.get("content")
    pieces = []

    if isinstance(content, str):
        pieces.append(content)
    elif isinstance(content, list):
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "text":
                pieces.append(block.get("text", ""))
            elif btype == "thinking":
                if THINKING and block.get("thinking"):
                    pieces.append("[thinking] " + block["thinking"])
            elif btype == "tool_use":
                if TOOLS == "none":
                    continue
                name = block.get("name", "tool")
                if TOOLS == "summary":
                    pieces.append(f"[tool: {name}] {summarize_tool_input(name, block.get('input'))}")
                else:
                    body = json.dumps(block.get("input"), ensure_ascii=False, indent=2)
                    pieces.append(f"[tool: {name}]\n{body}")
            elif btype == "tool_result":
                if TOOLS != "full":
                    continue
                text = block_text(block)
                if text:
                    pieces.append(f"[tool result]\n{text}")
            elif btype == "image":
                pieces.append("<image>")

    text = "\n\n".join(p for p in pieces if p and p.strip())
    if not text.strip():
        return None
    return role, record.get("timestamp"), text


def read_transcript(path):
    messages, meta_cwd, branch = [], None, None
    try:
        fh = open(path, "r", errors="replace")
    except OSError as exc:
        log(f"cannot read {path}: {exc}")
        return None
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get("cwd") and not meta_cwd:
                meta_cwd = record["cwd"]
            if record.get("gitBranch"):
                branch = record["gitBranch"]
            if record.get("type") not in ("user", "assistant"):
                continue
            if record.get("isSidechain") and not SIDECHAINS:
                continue
            # isMeta marks harness-injected turns (hook output, command
            # caveats). They are not conversation and only add noise.
            if record.get("isMeta"):
                continue
            if CUTOFF is not None:
                ts = parse_ts(record.get("timestamp"))
                if ts is not None and ts < CUTOFF:
                    continue
            rendered = render_message(record)
            if rendered:
                messages.append(rendered)
    return {"path": path, "cwd": meta_cwd, "branch": branch, "messages": messages}


# ── output ─────────────────────────────────────────────────────────────────
def cap(text):
    if MAXBYTES and len(text.encode("utf-8")) > MAXBYTES:
        clipped = text.encode("utf-8")[:MAXBYTES].decode("utf-8", "ignore")
        return clipped + f"\n\n[truncated to {MAXBYTES} bytes by --max-bytes]\n"
    return text


def emit_markdown(session):
    head = [f"=== session: {session['name']} ==="]
    if session["cwd"]:
        head.append(f"cwd: {session['cwd']}")
    if session["branch"]:
        head.append(f"branch: {session['branch']}")
    head.append(f"transcript: {session['path']}")
    if session["aliases"]:
        head.append("also open in: " + ", ".join(session["aliases"]))
    if not session["has_agent"]:
        head.append("note: resolved by directory — no agent running in that pane now")
    head.append(session["counts"])
    body = []
    for role, ts, text in session["messages"]:
        stamp = f" {ts}" if ts else ""
        body.append(f"\n--- {role}{stamp} ---\n{text}")
    return "\n".join(head) + "\n" + "\n".join(body) + "\n"


def xml_escape(text):
    return (str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def emit_xml(session):
    out = [
        f'<session name="{xml_escape(session["name"])}" cwd="{xml_escape(session["cwd"] or "")}"'
        f' branch="{xml_escape(session["branch"] or "")}">'
    ]
    for role, ts, text in session["messages"]:
        out.append(f'  <message role="{role}" timestamp="{xml_escape(ts or "")}">')
        out.append(xml_escape(text))
        out.append("  </message>")
    out.append("</session>")
    return "\n".join(out) + "\n"


def dedupe(sessions):
    """One transcript, one entry.

    Transcripts are keyed by working directory, so every session parked in the
    same directory resolves to the same file. Emitting each of them separately
    would put N identical copies of one conversation in the bundle under N
    different names — expensive and actively misleading about who said what.
    The session actually running an agent gets the attribution; the rest are
    recorded as aliases so nothing the screenshot pointed at disappears.
    """
    groups = {}
    for session in sessions:
        groups.setdefault(session["path"], []).append(session)
    out = []
    for path, group in groups.items():
        primary = next((s for s in group if s["has_agent"]), group[0])
        primary["aliases"] = [s["name"] for s in group if s is not primary]
        out.append(primary)
    return out


def main():
    picked = []
    with open(MANIFEST) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            while len(parts) < 4:
                parts.append("")
            picked.append((parts[0], parts[1], parts[2], parts[3] == "1"))

    misses, sessions = [], []
    for name, cwd, store_dir, has_agent in picked:
        paths = transcripts_for(cwd, store_dir) if (cwd or store_dir) else []
        if not paths:
            log(f"no transcript for {name} (cwd={cwd or '?'} store={store_dir or '?'})")
            misses.append((name, cwd))
            continue
        got = False
        for path in paths:
            data = read_transcript(path)
            if data is None or not data["messages"]:
                continue
            total = len(data["messages"])
            messages = data["messages"]
            if TURNS > 0 and total > TURNS:
                messages = messages[-TURNS:]
            counts = f"messages: {total}"
            if len(messages) != total:
                counts += f" (showing last {len(messages)})"
            if SINCE:
                counts += f" · filtered to last {SINCE}"
            sessions.append({
                "name": name,
                "cwd": data["cwd"] or cwd,
                "branch": data["branch"],
                "path": path,
                "counts": counts,
                "messages": messages,
                "has_agent": has_agent,
                "aliases": [],
            })
            got = True
        if not got:
            misses.append((name, cwd))

    sessions = dedupe(sessions)

    with open(MISSES, "w") as fh:
        for name, cwd in misses:
            fh.write(f"{name}\t{cwd}\n")

    if not sessions:
        return

    # Consumed and stripped by the caller, which uses them for its report.
    for session in sessions:
        sys.stdout.write(f"#RESOLVED\t{session['name']}\t{session['path']}\n")

    if LIST_ONLY:
        for session in sessions:
            print(f"  ✓ {session['name']}")
            print(f"      cwd:        {session['cwd']}")
            print(f"      branch:     {session['branch'] or '-'}")
            print(f"      transcript: {session['path']}")
            if session["aliases"]:
                print(f"      also open in: {', '.join(session['aliases'])}")
            print(f"      {session['counts']}")
        return

    if FORMAT == "json":
        payload = [{
            "session": s["name"],
            "cwd": s["cwd"],
            "branch": s["branch"],
            "transcript": s["path"],
            "aliases": s["aliases"],
            # Capping the serialised blob would truncate mid-token and hand
            # back something that will not parse, so the limit is applied to
            # the message text instead — the only field big enough to matter.
            "messages": [
                {"role": r, "timestamp": t, "text": cap(scrub(x))} for r, t, x in s["messages"]
            ],
        } for s in sessions]
        sys.stdout.write(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
        return

    render = emit_xml if FORMAT == "xml" else emit_markdown
    for session in sessions:
        sys.stdout.write("\n" + cap(scrub(render(session))))


if __name__ == "__main__":
    main()
