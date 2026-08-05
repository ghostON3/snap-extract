#!/usr/bin/env bash
# snap-extract — screenshot a file tree, get its contents in your clipboard.
#
# Run with --help for usage. Everything runs locally; no cloud calls.
#
# EXIT CODES
#   0  ok
#   2  bad invocation
#   3  identification step failed / no files readable

set -euo pipefail

MODE=""
BACKEND="tesseract"
IMAGE=""
FOLDER=""
PATHS=""
ROOT="${PWD}"
EXTS=".md"
EXCLUDE=""
INCLUDE=""
OUTPUT="clipboard"
MODEL="qwen3-vl:8b"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
MAX_DEPTH=8
RECURSIVE=0
DEBUG=0
NOTIFY=0

# ── tmux / conversation target ──────────────────────────────────────────────
# TARGET switches what an identified name means. "files" is the original
# behaviour; "sessions" treats each name as a tmux session and resolves it to
# the Claude Code transcript for that pane's working directory.
TARGET="files"
SESSIONS=""
ALL_SESSIONS=0
LIST_ONLY=0
STORES="${HOME}/.claude*"
TURNS=0
TOOLS="summary"
THINKING=0
SIDECHAINS=0
SINCE=""
FALLBACK="pane"
SCROLLBACK=2000
MAX_BYTES=0
REDACT=""
NO_REDACT=0
FORMAT="markdown"
ALL_TRANSCRIPTS=0
IGNORE_WORDS=""
# Directories never worth concatenating — pruned in recursive folder mode.
PRUNE_DIRS=".git,node_modules,dist,build,out,.next,.turbo,.svelte-kit,coverage,__pycache__,.venv,venv,target,vendor"

usage() {
  # Help goes to stdout so `--help | less` works; an invocation error sends it
  # to stderr so it never pollutes --output stdout. Dumping the file's own
  # header comments (the old behaviour) told the user nothing they needed.
  local stream=1
  [[ "${1:-0}" -ne 0 ]] && stream=2
  cat >&"$stream" <<'HELP'
snap-extract — screenshot a file tree, get its contents in your clipboard.

USAGE
  snap-extract.sh --screenshot --root DIR [options]
  snap-extract.sh --folder DIR [-r] [options]
  snap-extract.sh --paths "a.ts,b.ts" --root DIR [options]
  snap-extract.sh --image FILE --root DIR [options]

  Keep the whole command on ONE line. A pasted multi-line command with
  backslash continuations is mangled by some terminals.

INPUT MODES (choose exactly one)
  --screenshot        Drag a region with the mouse, then OCR it.
  --folder DIR        Skip OCR, read DIR directly.
  --paths "a,b"       Skip OCR, use these names (resolved under --root).
  --image FILE        OCR an existing image instead of capturing one.

OPTIONS
  --root DIR          Where filenames are resolved. Default: current directory.
                      Keep it scoped to one project; pointing it at $HOME is
                      slow and matches unrelated files.
  --ext ".ts,.md"     Extensions to include. Default: .md
  -r, --recursive     Walk the whole tree, not just immediate children.
  --max-depth N       Depth limit when recursing. Default: 8
  --prune "a,b"       Directory names to skip when recursing.
                      Default: .git, node_modules, dist, build, out, .next,
                      .turbo, .svelte-kit, coverage, __pycache__, .venv, venv,
                      target, vendor
  --exclude "*.test.ts"  Drop matching files (glob; matches path or basename).
  --include "*.ts"    Keep only matching files.
  --output DEST       clipboard (default) | stdout | a file path
  --backend NAME      tesseract (default, fast) | vision (local Ollama)
  --model NAME        Vision model. Default: qwen3-vl:8b
  --ollama-host URL   Default: http://localhost:11434
  --debug             Log OCR output and promotion decisions to stderr.
  --notify            Desktop notification with the result. Use this in
                      compositor keybinds, where there is no terminal to read.
  -h, --help          This text.

TMUX CONVERSATION MODE
  Same pointer trick, different target: instead of filenames, the screenshot
  is read for tmux session names. Each one that matches a live session is
  resolved to that pane's working directory, and the Claude Code transcript
  for that directory is read from disk. Truncated status lines do not matter.

  --tmux              Identified names are tmux sessions, not files. Combine
                      with --screenshot, --image, or --paths.
  --sessions "a,b"    Use these session names directly (implies --tmux).
  --all-sessions      Every live tmux session (implies --tmux).
  --list              Print the resolved session -> cwd -> transcript table
                      and exit. Use this to check a selection before copying.

  --store "GLOB"      Where transcripts live. Default: $HOME/.claude*
                      Comma-separated; each entry may be a glob.
  --all-transcripts   Every transcript for a directory, not just the newest.

  --turns N           Keep only the last N messages per session. 0 = all.
  --since DUR         Keep only messages newer than DUR (30m, 6h, 3d).
  --tools MODE        full | summary (default) | none. Controls how much of
                      each tool call is kept. "full" includes tool output and
                      gets very large; "summary" keeps one line per call.
  --thinking          Include assistant thinking blocks. Off by default.
  --sidechains        Include subagent sidechains. Off by default.
  --max-bytes N       Truncate each session to N bytes. 0 = unlimited.

  --fallback MODE     pane (default) | none. What to do for a session with no
                      transcript: capture the tmux scrollback, or skip it.
  --scrollback N      Lines of scrollback for the pane fallback. Default: 2000

  --redact "re,re"    Extra regexes to mask (Python syntax).
  --no-redact         Disable the built-in secret masking. Off by default,
                      meaning secrets ARE masked unless you pass this.
  --format FMT        markdown (default) | xml | json
  --ignore "a,b"      Extra status-bar words that must never fuzzy-match a
                      session name. Built-ins already cover claude, branch,
                      ctx, dir, main and similar chrome.

EXAMPLES
  # Screenshot your editor's file tree into the clipboard
  snap-extract.sh --screenshot --root ~/projects/app --ext ".ts,.tsx"

  # Whole package tree, straight to the clipboard
  snap-extract.sh --folder ~/projects/app/packages -r --ext ".ts,.json"

  # Preview what would be copied, without touching the clipboard
  snap-extract.sh --folder ~/notes --ext .md --output stdout | head -40

  # Write to a file instead
  snap-extract.sh --folder ~/notes -r --output /tmp/notes.md

  # Skip tests
  snap-extract.sh --folder ~/projects/app -r --ext .ts --exclude "*.test.ts"

  # Screenshot a tmux grid, copy every conversation in it
  snap-extract.sh --screenshot --tmux

  # Check what a screenshot resolved to before copying anything
  snap-extract.sh --screenshot --tmux --list

  # Two named sessions, last 40 messages each, tool calls dropped
  snap-extract.sh --sessions "elo-evo-v2,c-ghost-4" --turns 40 --tools none

  # Everything from the last two hours, as XML, to a file
  snap-extract.sh --all-sessions --since 2h --format xml --output /tmp/ctx.xml

HOW THE SCREENSHOT WORKS
  --screenshot runs slurp: the cursor becomes a crosshair. Drag a rectangle
  over your editor's file tree (or click a window to select all of it).
  Press Escape to cancel. OCR then reads the filenames; as soon as one
  resolves on disk, its whole directory is read instead — so a few misread
  names do not matter.

EXIT CODES
  0  ok    2  bad invocation    3  nothing identified or readable
HELP
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --screenshot)  MODE="screenshot"; shift ;;
    --image)       MODE="image"; IMAGE="$2"; shift 2 ;;
    --folder)      MODE="folder"; FOLDER="$2"; shift 2 ;;
    --paths)       MODE="paths"; PATHS="$2"; shift 2 ;;
    --backend)     BACKEND="$2"; shift 2 ;;
    --root)        ROOT="$2"; shift 2 ;;
    --ext)         EXTS="$2"; shift 2 ;;
    --exclude)     EXCLUDE="$2"; shift 2 ;;
    --include)     INCLUDE="$2"; shift 2 ;;
    --output)      OUTPUT="$2"; shift 2 ;;
    --model)       MODEL="$2"; shift 2 ;;
    --ollama-host) OLLAMA_HOST="$2"; shift 2 ;;
    --max-depth)   MAX_DEPTH="$2"; shift 2 ;;
    -r|--recursive) RECURSIVE=1; shift ;;
    --prune)       PRUNE_DIRS="$2"; shift 2 ;;
    --debug)       DEBUG=1; shift ;;
    --notify)      NOTIFY=1; shift ;;
    --tmux)        TARGET="sessions"; shift ;;
    --sessions)    TARGET="sessions"; SESSIONS="$2"; shift 2 ;;
    --all-sessions) TARGET="sessions"; ALL_SESSIONS=1; shift ;;
    --list)        LIST_ONLY=1; shift ;;
    --store)       STORES="$2"; shift 2 ;;
    --all-transcripts) ALL_TRANSCRIPTS=1; shift ;;
    --turns)       TURNS="$2"; shift 2 ;;
    --since)       SINCE="$2"; shift 2 ;;
    --tools)       TOOLS="$2"; shift 2 ;;
    --thinking)    THINKING=1; shift ;;
    --sidechains)  SIDECHAINS=1; shift ;;
    --max-bytes)   MAX_BYTES="$2"; shift 2 ;;
    --fallback)    FALLBACK="$2"; shift 2 ;;
    --scrollback)  SCROLLBACK="$2"; shift 2 ;;
    --redact)      REDACT="$2"; shift 2 ;;
    --no-redact)   NO_REDACT=1; shift ;;
    --ignore)      IGNORE_WORDS="$2"; shift 2 ;;
    --format)      FORMAT="$2"; shift 2 ;;
    -h|--help)     usage 0 ;;
    *)
      echo "snap-extract: unknown argument: $1" >&2
      if [[ "$1" == *\\* || "$1" == E ]]; then
        echo "snap-extract: that looks like a mangled line continuation — retype the command on one line." >&2
      fi
      echo >&2
      usage 2
      ;;
  esac
done

log() { [[ $DEBUG -eq 1 ]] && echo "[snap-extract] $*" >&2 || true; }

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  printf '%s' "${value%"${value##*[![:space:]]}"}"
}

contains() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

has_allowed_extension() {
  local name="${1,,}" ext
  local -a extensions
  IFS=',' read -ra extensions <<< "$EXTS"
  for ext in "${extensions[@]}"; do
    ext="$(trim "$ext")"
    [[ -n "$ext" && "$name" == *"${ext,,}" ]] && return 0
  done
  return 1
}

# Collection emits absolute paths (find echoes its starting point verbatim), but
# resolve() looks names up as "$ROOT/$name". With a relative --folder the two
# disagree and every file comes back unresolved. Canonicalise up front so both
# halves always speak absolute paths.
abs_dir() {
  local p="$1"
  [[ -d "$p" ]] && { (cd "$p" && pwd); return 0; }
  printf '%s' "${p%/}"
}
[[ -n "$FOLDER" ]] && FOLDER="$(abs_dir "$FOLDER")"
ROOT="$(abs_dir "$ROOT")"

# When launched from a compositor keybind there is no terminal to read, so a
# failure is otherwise completely silent — you cannot tell "copied 40 files"
# from "copied nothing". urgency=critical on failure so it does not auto-dismiss.
notify() {
  [[ $NOTIFY -eq 1 ]] || return 0
  command -v notify-send &>/dev/null || return 0
  local urgency="$1" title="$2" body="$3"
  notify-send -a snap-extract -u "$urgency" "$title" "$body" 2>/dev/null || true
}

# Failure exits are scattered; route them all through here so --notify covers
# every one of them rather than only the last.
die() {
  local code="$1" msg="$2" detail="${3:-}"
  echo "snap-extract: $msg" >&2
  [[ -n "$detail" ]] && echo "  $detail" >&2
  notify critical "snap-extract: nothing copied" "${detail:-$msg}"
  exit "$code"
}

# --sessions and --all-sessions name their input outright, so they are input
# modes in their own right and must not trip the "pick an input mode" error.
if [[ "$TARGET" == "sessions" && -z "$MODE" ]]; then
  if [[ $ALL_SESSIONS -eq 1 || -n "$SESSIONS" ]]; then
    MODE="sessions"
  fi
fi

# ── Step 1: get an image (if needed) ────────────────────────────────────────
if [[ "$MODE" == "screenshot" ]]; then
  IMAGE="$(mktemp --suffix=.png)"
  IMAGE_IS_TEMP=1
  log "capturing region → $IMAGE"
  if command -v grim &>/dev/null && command -v slurp &>/dev/null; then
    grim -g "$(slurp)" "$IMAGE"
  elif command -v scrot &>/dev/null; then
    scrot -s "$IMAGE"
  else
    die 2 "no screenshot tool" "Install grim + slurp (Wayland) or scrot (X11)."
  fi
  [[ -s "$IMAGE" ]] || die 3 "screenshot cancelled" "No region was selected."
  MODE="image"
fi

# ── Step 2a: identify file names via tesseract (fast, CPU) ─────────────────

# Tesseract is trained on large, dark-on-light text. An editor sidebar is the
# opposite on every dark theme: ~13px light glyphs on a dark background. Fed
# raw, it drops the dot before the extension ("contract.ts" → "contractts"),
# which the extension regex then rejects — so a whole screenshot yields
# nothing. Normalising the image first is the difference between unusable and
# reliable, so do it whenever ImageMagick is available.
preprocess_for_ocr() {
  local src="$1" dst="$2" im=""
  if command -v magick &>/dev/null; then im="magick"
  elif command -v convert &>/dev/null; then im="convert"
  else return 1; fi

  local mean
  mean="$("$im" "$src" -colorspace Gray -format "%[fx:mean]" info: 2>/dev/null)" || return 1
  [[ -n "$mean" ]] || return 1

  # Mean luminance below half means light-on-dark: flip it.
  local -a negate=()
  if awk "BEGIN{exit !($mean < 0.5)}" 2>/dev/null; then
    negate=(-negate)
    log "preprocess: dark background (mean=$mean) → inverting"
  fi
  "$im" "$src" -colorspace Gray ${negate[@]+"${negate[@]}"} \
    -resize 400% -sharpen 0x1 "$dst" 2>/dev/null || return 1
  return 0
}

identify_via_tesseract() {
  local img="$1"
  command -v tesseract &>/dev/null || { echo "tesseract not installed" >&2; return 2; }

  local ocr_src="$img" prepped=""
  prepped="$(mktemp --suffix=.png)"
  if preprocess_for_ocr "$img" "$prepped"; then
    ocr_src="$prepped"
    log "preprocess: grayscale + 4x upscale + sharpen"
  else
    log "preprocess: skipped (ImageMagick unavailable) — OCR accuracy will suffer"
  fi

  # --psm 6 ("uniform block of text") beats the default auto-segmentation on a
  # narrow column of filenames; fall back to auto if it comes back empty.
  local raw
  raw="$(tesseract "$ocr_src" - --psm 6 2>/dev/null)" || raw=""
  # Plain `[[ ... ]] && x` would return 1 when the test is false, and `set -e`
  # kills the script on that. Use a real if.
  if [[ -z "${raw//[[:space:]]/}" ]]; then
    raw="$(tesseract "$ocr_src" - 2>/dev/null)" || raw=""
  fi
  rm -f "$prepped"
  [[ -n "${raw//[[:space:]]/}" ]] || return 2

  # Session mode does its own token extraction and filters against the tmux
  # session list, so the extension machinery below would throw away every
  # candidate before it got the chance. Hand back the raw read.
  if [[ "$TARGET" == "sessions" ]]; then
    printf '%s\n' "$raw"
    return 0
  fi

  # Build a regex from --ext (".md,.sh" → "\.md|\.sh") and extract tokens
  # that look like file names (basename + extension). Limit to plausible
  # name chars to avoid pulling whole sentences.
  local ext_regex bare_regex
  ext_regex="$(echo "$EXTS" | sed -E 's/[, ]+/|/g; s/\./\\./g')"
  # Same list without the dots, for recovering names whose dot the OCR ate.
  bare_regex="$(echo "$EXTS" | sed -E 's/[, ]+/|/g; s/\.//g')"
  # Every grep here needs `|| true`: a grep that matches nothing exits 1, and
  # under `pipefail` that failure propagates out as the function's status —
  # which the caller reports as "tesseract failed" even when the other branch
  # found plenty. Once preprocessing works, the recovery branch matching
  # nothing is the *normal* case, so this is not a corner case at all.
  local primary recovered
  primary="$(grep -oiE "[A-Za-z0-9][A-Za-z0-9_.+-]{0,100}(${ext_regex})" <<<"$raw" || true)"
  # Dot recovery: "contractts" → "contract.ts". Also handles the variant where
  # OCR turns the dot into a space ("dark ts"). False positives are free — a
  # name that doesn't exist on disk is discarded downstream.
  recovered="$(sed -E "s/([A-Za-z0-9])[[:space:]]+(${bare_regex})\b/\1.\2/gI" <<<"$raw" \
    | { grep -oiE "[A-Za-z0-9][A-Za-z0-9_+-]{0,100}(${bare_regex})\b" || true; } \
    | sed -E "s/(${bare_regex})$/.\1/I" || true)"

  printf '%s\n%s\n' "$primary" "$recovered" | { grep -v '^[[:space:]]*$' || true; } | sort -u
}

# ── Step 2b: identify file names via vision (qwen3-vl, slow on CPU) ────────
identify_via_vision() {
  local img="$1"
  local prompt_file
  prompt_file="$(dirname "$0")/prompts/identify.txt"
  local prompt
  if [[ -f "$prompt_file" ]]; then
    prompt="$(cat "$prompt_file")"
  else
    prompt='List every file or folder NAME visible in this screenshot. Output ONE name per line. NO commentary, NO bullets, NO markdown, NO thinking.'
  fi

  log "calling ollama @ $OLLAMA_HOST/api/generate (model=$MODEL)"
  # /no_think prefix suppresses qwen3 chain-of-thought (the `think` API field
  # is not always honored). keep_alive=15m keeps the model resident so repeat
  # invocations don't pay the cold-load tax.
  PROMPT="/no_think
$prompt" IMG_PATH="$img" MODEL="$MODEL" OLLAMA_HOST="$OLLAMA_HOST" \
    python3 - <<'PYEOF'
import base64, json, os, sys, urllib.request
with open(os.environ['IMG_PATH'], 'rb') as f:
    b64 = base64.b64encode(f.read()).decode()
req_body = json.dumps({
    'model': os.environ['MODEL'],
    'prompt': os.environ['PROMPT'],
    'stream': False,
    'think': False,
    'keep_alive': '15m',
    'images': [b64],
    'options': {'temperature': 0.0, 'num_predict': 512},
}).encode()
url = os.environ['OLLAMA_HOST'].rstrip('/') + '/api/generate'
req = urllib.request.Request(url, data=req_body, headers={'Content-Type': 'application/json'})
try:
    with urllib.request.urlopen(req, timeout=600) as resp:
        data = json.loads(resp.read())
        print(data.get('response', ''))
except Exception as e:
    print(f'VISION_ERROR: {e}', file=sys.stderr)
    sys.exit(2)
PYEOF
}

# ── tmux session resolution ─────────────────────────────────────────────────
# The file pipeline resolves a name by looking for it on disk. The session
# pipeline resolves a name by looking for it in `tmux list-sessions`, which is
# just as authoritative and just as intolerant of OCR noise: a misread token
# matches nothing and is silently dropped, exactly like an unresolvable
# filename. Matching widens in stages so a status line truncated to
# "ssh-temporal-ac…" still lands.

tmux_available() { command -v tmux &>/dev/null && tmux list-sessions &>/dev/null; }

# name -> "cwd<TAB>1|0", where the flag says whether a pane in this session is
# actually running an agent. A session's claude process is not always in pane 0,
# so prefer a pane running one.
#
# The flag matters because a transcript is keyed by directory, not by session:
# every shell sitting in $HOME resolves to the same $HOME conversation. Knowing
# which of them is the one that actually held it is the difference between one
# labelled conversation and six copies attributed to sessions that never had it.
session_pane_info() {
  local s="$1" line panes
  panes="$(tmux list-panes -t "$s" -F '#{pane_current_command}	#{pane_current_path}' 2>/dev/null || true)"
  line="$(grep -m1 -E '^claude	' <<<"$panes" || true)"
  if [[ -n "$line" ]]; then
    printf '%s\t1' "${line#*	}"
    return 0
  fi
  line="$(head -1 <<<"$panes")"
  printf '%s\t0' "${line#*	}"
}

# Lowercase, drop anything that is not alphanumeric. Survives the OCR turning
# a hyphen into an em dash, or eating it entirely.
#
# Writes through a named variable rather than echoing. A screenshot yields a
# couple of hundred candidate tokens and a busy machine has north of a thousand
# transcript directories; at one subshell per comparison that product is a
# quarter of a million forks, which takes minutes. Fork-free, it is instant.
norm_into() {
  local __v="${2,,}"
  printf -v "$1" '%s' "${__v//[^a-z0-9]/}"
}

# Normalised views of the two haystacks, built once. SLUG_NORMS is parallel to
# SLUG_PATHS.
declare -a SESSION_NORMS=() SLUG_NORMS=() SLUG_PATHS=()

build_match_tables() {
  local s d slug n
  for s in ${ALL_SESSION_NAMES[@]+"${ALL_SESSION_NAMES[@]}"}; do
    norm_into n "$s"
    SESSION_NORMS+=("$n")
  done
  for d in "${STORE_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    for slug in "$d"/*/; do
      slug="${slug%/}"; slug="${slug##*/}"
      [[ "$slug" == "*" ]] && continue
      norm_into n "$slug"
      SLUG_NORMS+=("$n")
      SLUG_PATHS+=("$d/$slug")
    done
  done
  log "match tables: ${#SESSION_NORMS[@]} sessions, ${#SLUG_PATHS[@]} transcript dirs"
}

# Words that are part of the status bar itself rather than anything anyone
# named. Every pane running an agent prints "1:claude*", so the bare token
# "claude" is in every screenshot — and it is a substring of any session called
# c-claude-4, which would then be pulled into every bundle. Chrome is still
# allowed to match a session *exactly*, because a session really can be called
# "main"; it is only barred from the fuzzy stages, where it means nothing.
CHROME="claude,branch,ctx,dir,main,master,bypass,permissions,agent,agents,node,zsh,bash,fish,git,session,sessions,window,windows,pane,panes,tokens,token,aug,jan,feb,mar,apr,jun,jul,sep,oct,nov,dec"
IGNORE="${IGNORE_WORDS:-}"

is_chrome() {
  local n="$1" w nw
  IFS=',' read -ra __CH <<< "$CHROME,$IGNORE"
  for w in "${__CH[@]}"; do
    norm_into nw "$(trim "$w")"
    [[ -n "$nw" && "$nw" == "$n" ]] && return 0
  done
  return 1
}

# Exact, then prefix (truncation), then substring either way. The first stage
# that yields anything wins, so a whole session is never dragged in by a short
# fragment that happens to appear inside its name.
match_session() {
  local nwant i
  norm_into nwant "$1"
  [[ ${#nwant} -ge 3 ]] || return 1
  local chrome=0
  is_chrome "$nwant" && chrome=1
  local -a exact=() prefix=() infix=()
  for i in "${!SESSION_NORMS[@]}"; do
    local ns="${SESSION_NORMS[$i]}"
    if [[ "$ns" == "$nwant" ]]; then exact+=("${ALL_SESSION_NAMES[$i]}")
    elif [[ $chrome -eq 1 ]]; then continue
    elif [[ "$ns" == "$nwant"* || "$nwant" == "$ns"* ]]; then prefix+=("${ALL_SESSION_NAMES[$i]}")
    elif [[ "$ns" == *"$nwant"* || "$nwant" == *"$ns"* ]]; then infix+=("${ALL_SESSION_NAMES[$i]}")
    fi
  done
  if   [[ ${#exact[@]}  -gt 0 ]]; then printf '%s\n' "${exact[@]}"
  elif [[ ${#prefix[@]} -gt 0 ]]; then printf '%s\n' "${prefix[@]}"
  elif [[ ${#infix[@]}  -gt 0 ]]; then printf '%s\n' "${infix[@]}"
  else return 1; fi
}

# A pane whose session has since been killed still has its transcript on disk,
# filed under a slug derived from its directory. Matching the OCR'd name
# against those slugs recovers conversations tmux can no longer account for —
# the usual fate of the finished worktree in a screenshot.
match_store_slug() {
  local nwant i
  norm_into nwant "$1"
  # Short fragments substring-match half the store. Demand a real name.
  [[ ${#nwant} -ge 6 ]] || return 1
  is_chrome "$nwant" && return 1
  local -a hits=()
  for i in "${!SLUG_NORMS[@]}"; do
    [[ "${SLUG_NORMS[$i]}" == *"$nwant"* ]] && hits+=("${SLUG_PATHS[$i]}")
  done
  [[ ${#hits[@]} -gt 0 ]] || return 1
  # The slug is a lossy encoding of the path (every separator became "-"), so
  # it is never decoded back; the real cwd is read out of the transcript.
  printf '%s\n' "${hits[@]}"
}

declare -a FILES=()

# ── Shared collector ────────────────────────────────────────────────────────
# Every mode funnels through this: given a directory, emit the absolute path of
# every file matching --ext. Honours --recursive, --max-depth and --prune, so
# screenshot mode and folder mode expand a directory identically. Emitting
# absolute paths means resolve() passes them straight through.
declare -a PRUNE_EXPR=()
IFS=',' read -ra PRUNE_ARR <<< "$PRUNE_DIRS"
for d in "${PRUNE_ARR[@]}"; do
  d="$(trim "$d")"
  [[ -z "$d" ]] && continue
  [[ ${#PRUNE_EXPR[@]} -gt 0 ]] && PRUNE_EXPR+=(-o)
  PRUNE_EXPR+=(-name "$d")
done

collect_folder() {
  local dir="${1%/}" depth=1
  [[ -d "$dir" ]] || return 0
  [[ $RECURSIVE -eq 1 ]] && depth="$MAX_DEPTH"
  local -a ext_arr
  IFS=',' read -ra ext_arr <<< "$EXTS"
  for ext in "${ext_arr[@]}"; do
    ext="$(trim "$ext")"
    [[ -z "$ext" ]] && continue
    if [[ $RECURSIVE -eq 1 && ${#PRUNE_EXPR[@]} -gt 0 ]]; then
      find "$dir" -maxdepth "$depth" \
        \( "${PRUNE_EXPR[@]}" \) -prune -o \
        -type f -iname "*${ext}" -print 2>/dev/null
    else
      find "$dir" -maxdepth "$depth" -type f -iname "*${ext}" -print 2>/dev/null
    fi
  done
}

resolve_in_root_any_depth() {
  local name="$1"
  [[ -f "$ROOT/$name" ]] && { echo "$ROOT/$name"; return 0; }
  [[ -d "$ROOT" ]] || return 1
  find "$ROOT" -maxdepth "$MAX_DEPTH" -type f -iname "$name" -print -quit 2>/dev/null
}

resolve_all_in_root() {
  local name="$1"
  [[ -d "$ROOT" ]] || return 1
  find "$ROOT" -maxdepth "$MAX_DEPTH" -type f -iname "$name" -print 2>/dev/null
}

promote_identified_files() {
  [[ -d "$ROOT" ]] || return 0

  local name directory candidate candidate_dir anchored file
  local -a matches=() promoted_dirs=() ambiguous_names=()

  # Unique filenames are reliable directory anchors. Defer common basenames
  # such as index.ts and HUMAN.MD until those anchors are known.
  for name in "${FILES[@]}"; do
    mapfile -t matches < <(resolve_all_in_root "$name" || true)
    [[ ${#matches[@]} -gt 0 ]] || continue
    if [[ ${#matches[@]} -gt 1 ]]; then
      ambiguous_names+=("$name")
      log "auto-promote: $name has ${#matches[@]} matches; deferring"
      continue
    fi

    directory="$(dirname "${matches[0]}")"
    contains "$directory" "${promoted_dirs[@]}" || promoted_dirs+=("$directory")
    log "auto-promote: $name → $directory"
  done

  # Prefer an already anchored directory for duplicate basenames. If the
  # screenshot contains only a common basename, keep the first-match fallback
  # so the simple one-file workflow still produces useful output.
  for name in "${ambiguous_names[@]}"; do
    mapfile -t matches < <(resolve_all_in_root "$name" || true)
    anchored=""
    for candidate in "${matches[@]}"; do
      candidate_dir="$(dirname "$candidate")"
      if contains "$candidate_dir" "${promoted_dirs[@]}"; then
        anchored="$candidate_dir"
        break
      fi
    done
    if [[ -n "$anchored" ]]; then
      log "auto-promote: $name → $anchored (anchored by unique name)"
      continue
    fi

    directory="$(dirname "${matches[0]}")"
    contains "$directory" "${promoted_dirs[@]}" || promoted_dirs+=("$directory")
    log "auto-promote: $name → $directory (ambiguous fallback)"
  done

  [[ ${#promoted_dirs[@]} -gt 0 ]] || return 0

  FILES=()
  while IFS= read -r file; do
    [[ -n "$file" ]] && FILES+=("$file")
  done < <(
    for directory in "${promoted_dirs[@]}"; do collect_folder "$directory"; done | sort -u
  )

  # Use the deepest common ancestor for concise, unambiguous output labels.
  ROOT="${promoted_dirs[0]}"
  for directory in "${promoted_dirs[@]}"; do
    while [[ "$directory/" != "$ROOT/"* ]]; do
      ROOT="$(dirname "$ROOT")"
      [[ "$ROOT" == "/" ]] && break
    done
  done
  log "promoted ${#promoted_dirs[@]} dir(s) → ${#FILES[@]} files, root=$ROOT"
}

case "$MODE" in
  image)
    [[ -f "$IMAGE" ]] || die 2 "image not found: $IMAGE"
    log "identification on $IMAGE (backend=$BACKEND)"
    case "$BACKEND" in
      tesseract)
        raw="$(identify_via_tesseract "$IMAGE")" || die 3 "OCR failed" "tesseract could not read the image. Re-run with --debug."
        ;;
      vision)
        raw="$(identify_via_vision "$IMAGE")" || die 3 "vision backend failed" "Is Ollama running at $OLLAMA_HOST?"
        ;;
      *)
        die 2 "unknown backend: $BACKEND" "Use tesseract or vision."
        ;;
    esac
    log "raw identification output:"
    log "$raw"

    # In session mode the extension regex is meaningless — a tmux status line
    # has no file extensions in it. Take every token that could plausibly be a
    # session name and let the tmux/store lookup do the filtering, the same way
    # the file pipeline lets the filesystem do it.
    if [[ "$TARGET" == "sessions" ]]; then
      while IFS= read -r name; do
        name="$(trim "$name")"
        [[ -n "$name" ]] && FILES+=("$name")
      done < <(grep -oE '[A-Za-z][A-Za-z0-9_.-]{2,60}' <<<"$raw" | sort -u)
      log "session-name candidates: ${#FILES[@]}"
    else
      fence_char=$'\x60'  # backtick — code-fence sentinel from markdown output
      while IFS= read -r name; do
        name="$(echo "$name" | sed -E 's/^[[:space:]]*[-•*]?[[:space:]]*//; s/[[:space:]]+$//')"
        [[ -z "$name" ]] && continue
        # Strip markdown code-fence lines, horizontal rules, heading underlines.
        [[ "${name:0:1}" == "$fence_char" ]] && continue
        [[ "$name" =~ ^---+$ ]] && continue
        [[ "$name" =~ ^===+$ ]] && continue
        FILES+=("$name")
      done <<< "$raw"

      # OCR only needs one reliable name. Once a directory is identified, disk
      # becomes authoritative and supplies the complete file list.
      promote_identified_files
    fi
    ;;
  sessions)
    IFS=',' read -ra S <<< "$SESSIONS"
    for s in "${S[@]}"; do
      s="$(trim "$s")"
      [[ -n "$s" ]] && FILES+=("$s")
    done
    ;;
  folder)
    [[ -d "$FOLDER" ]] || die 2 "folder not found: $FOLDER"
    ROOT="${FOLDER%/}"
    while IFS= read -r f; do
      [[ -n "$f" ]] && FILES+=("$f")
    done < <(collect_folder "$ROOT" | sort -u)
    ;;
  paths)
    IFS=',' read -ra P <<< "$PATHS"
    for p in "${P[@]}"; do
      FILES+=("$(trim "$p")")
    done
    ;;
  *)
    echo "snap-extract: pick an input mode — --screenshot, --folder, --paths, --image, --sessions, or --all-sessions" >&2
    echo >&2
    usage 2
    ;;
esac

# ── Session pipeline ────────────────────────────────────────────────────────
# Runs instead of steps 3 and 4 when --tmux is in play. Produces the same
# $out_tmp the file pipeline does, so step 5 (output, report, notify) is shared.
if [[ "$TARGET" == "sessions" ]]; then
  command -v python3 &>/dev/null || die 2 "python3 required" "Transcript rendering needs python3."

  # Expand --store globs once. Unmatched globs must not survive as literals.
  declare -a STORE_DIRS=()
  IFS=',' read -ra STORE_PATTERNS <<< "$STORES"
  for pat in "${STORE_PATTERNS[@]}"; do
    pat="$(trim "$pat")"
    [[ -z "$pat" ]] && continue
    for d in $(eval echo "$pat" 2>/dev/null); do
      [[ -d "$d/projects" ]] && STORE_DIRS+=("$d/projects")
      [[ -d "$d" && "$(basename "$d")" == "projects" ]] && STORE_DIRS+=("$d")
    done
  done
  [[ ${#STORE_DIRS[@]} -gt 0 ]] || die 3 "no transcript store found" \
    "Looked for projects/ under: $STORES. Point --store somewhere else."
  log "stores: ${STORE_DIRS[*]}"

  declare -a ALL_SESSION_NAMES=()
  if tmux_available; then
    mapfile -t ALL_SESSION_NAMES < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
  fi
  log "live tmux sessions: ${#ALL_SESSION_NAMES[@]}"
  build_match_tables

  # name<TAB>cwd<TAB>store-dir-or-empty, deduped by the pair that follows.
  declare -a PICKED=()
  declare -a SESSION_SKIPPED=()

  # Empty-array expansion is only safe under `set -u` from bash 4.4 on, and the
  # README promises bash 4. Guard every expansion that can legitimately be empty.
  add_pick() {
    local entry="$1"
    contains "$entry" ${PICKED[@]+"${PICKED[@]}"} || PICKED+=("$entry")
  }

  if [[ $ALL_SESSIONS -eq 1 ]]; then
    tmux_available || die 3 "no tmux server" "--all-sessions needs a running tmux."
    for s in "${ALL_SESSION_NAMES[@]}"; do
      IFS=$'\t' read -r pcwd pagent <<< "$(session_pane_info "$s")"
      add_pick "$s	$pcwd		$pagent"
    done
  else
    for name in "${FILES[@]}"; do
      hit=0
      while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        IFS=$'\t' read -r pcwd pagent <<< "$(session_pane_info "$s")"
        add_pick "$s	$pcwd		$pagent"
        hit=1
        log "session match: $name → $s"
      done < <(match_session "$name" || true)
      if [[ $hit -eq 0 ]]; then
        # No live session. The transcript may still be on disk under a slug.
        while IFS= read -r slugdir; do
          [[ -z "$slugdir" ]] && continue
          add_pick "$name		$slugdir	0"
          hit=1
          log "store match: $name → $slugdir"
        done < <(match_store_slug "$name" || true)
      fi
      [[ $hit -eq 0 ]] && SESSION_SKIPPED+=("$name (no session or transcript)")
    done
  fi

  [[ ${#PICKED[@]} -gt 0 ]] || die 3 "no sessions identified" \
    "${#FILES[@]} name(s) read, none matched a tmux session or transcript directory. Re-run with --debug, or name them with --sessions."

  manifest="$(mktemp)"
  printf '%s\n' "${PICKED[@]}" > "$manifest"
  misses="$(mktemp)"
  out_tmp="$(mktemp)"

  SNAP_MANIFEST="$manifest" SNAP_MISSES="$misses" \
  SNAP_STORES="$(printf '%s\n' "${STORE_DIRS[@]}")" \
  SNAP_TURNS="$TURNS" SNAP_TOOLS="$TOOLS" SNAP_THINKING="$THINKING" \
  SNAP_SIDECHAINS="$SIDECHAINS" SNAP_SINCE="$SINCE" SNAP_FORMAT="$FORMAT" \
  SNAP_MAXBYTES="$MAX_BYTES" SNAP_REDACT="$REDACT" SNAP_NOREDACT="$NO_REDACT" \
  SNAP_ALL_TRANSCRIPTS="$ALL_TRANSCRIPTS" SNAP_LIST="$LIST_ONLY" SNAP_DEBUG="$DEBUG" \
    python3 "$(dirname "$0")/lib/render_sessions.py" > "$out_tmp" || {
      rm -f "$manifest" "$misses"
      die 3 "transcript rendering failed" "Re-run with --debug for the traceback."
    }

  # Sessions with no transcript: fall back to the pane's scrollback if asked.
  # Lossy and ANSI-stripped, but a shell pane or a pre-transcript session is
  # otherwise invisible, and silently dropping it reads as "there was nothing".
  declare -a RESOLVED=()
  while IFS=$'\t' read -r sname scwd; do
    [[ -z "$sname" ]] && continue
    if [[ "$FALLBACK" == "pane" ]] && tmux_available \
       && contains "$sname" ${ALL_SESSION_NAMES[@]+"${ALL_SESSION_NAMES[@]}"}; then
      pane_txt="$(tmux capture-pane -p -J -S "-${SCROLLBACK}" -t "$sname" 2>/dev/null || true)"
      pane_txt="$(sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g' <<<"$pane_txt" | { grep -v '^[[:space:]]*$' || true; })"
      if [[ -n "$pane_txt" ]]; then
        {
          printf '\n=== session: %s (tmux scrollback — no transcript matched) ===\n' "$sname"
          printf 'cwd: %s\n\n' "$scwd"
          printf '%s\n' "$pane_txt"
        } >> "$out_tmp"
        RESOLVED+=("$sname (scrollback)")
        continue
      fi
    fi
    SESSION_SKIPPED+=("$sname (no transcript)")
  done < "$misses"

  while IFS=$'\t' read -r sname spath; do
    [[ -n "$sname" ]] && RESOLVED+=("$sname → $spath")
  done < <({ grep -a '^#RESOLVED	' "$out_tmp" || true; } | cut -f2-)
  # The markers are metadata for this loop, not part of the bundle.
  sed -i '/^#RESOLVED\t/d' "$out_tmp"

  rm -f "$manifest" "$misses"

  if [[ $LIST_ONLY -eq 1 ]]; then
    cat "$out_tmp"
    { for s in "${SESSION_SKIPPED[@]}"; do printf '  ✗ %s\n' "$s"; done } >&2
    rm -f "$out_tmp"
    exit 0
  fi

  [[ -s "$out_tmp" ]] || { rm -f "$out_tmp"; die 3 "nothing to copy" \
    "Sessions resolved but every transcript was empty after filtering. Loosen --turns/--since."; }

  declare -a SKIPPED=("${SESSION_SKIPPED[@]}")
fi

if [[ "$TARGET" == "files" && ${#FILES[@]} -eq 0 ]]; then
  case "$MODE" in
    image) die 3 "nothing identified" "OCR found no names matching '$EXTS'. Re-run with --debug to see what it read." ;;
    *)     die 3 "nothing identified" "No '$EXTS' files under $ROOT. Add -r to recurse into subdirectories." ;;
  esac
fi

# ── Step 3: resolve + filter ────────────────────────────────────────────────
resolve() {
  local name="$1"
  # absolute path?
  [[ "$name" = /* ]] && [[ -f "$name" ]] && { echo "$name"; return 0; }
  # resolve against --root
  [[ -f "$ROOT/$name" ]] && { echo "$ROOT/$name"; return 0; }
  # resolve anywhere under --root, then promote to that file's folder upstream
  local nested
  nested="$(resolve_in_root_any_depth "$name" || true)"
  [[ -n "$nested" && -f "$nested" ]] && { echo "$nested"; return 0; }
  return 1
}

matches_any_glob() {
  local name="$1" patterns="$2"
  [[ -z "$patterns" ]] && return 1
  IFS=',' read -ra PATS <<< "$patterns"
  for pat in "${PATS[@]}"; do
    pat="$(trim "$pat")"
    # shellcheck disable=SC2053
    [[ "$name" == $pat ]] && return 0
    # In recursive mode names are relative paths — let "*.lock" still match
    # "pkg/a/b.lock" without forcing the user to write "*/*.lock".
    # shellcheck disable=SC2053
    [[ "$(basename "$name")" == $pat ]] && return 0
  done
  return 1
}

if [[ "$TARGET" == "files" ]]; then
declare -a RESOLVED=()
declare -a SKIPPED=()
for name in "${FILES[@]}"; do
  if [[ -n "$INCLUDE" ]] && ! matches_any_glob "$name" "$INCLUDE"; then
    SKIPPED+=("$name (include-miss)")
    continue
  fi
  if [[ -n "$EXCLUDE" ]] && matches_any_glob "$name" "$EXCLUDE"; then
    SKIPPED+=("$name (excluded)")
    continue
  fi
  # extension filter only applies in image/screenshot mode (folder mode pre-filtered)
  if [[ "$MODE" == "image" ]] || [[ "$MODE" == "paths" ]]; then
    has_allowed_extension "$name" || { SKIPPED+=("$name (ext-miss)"); continue; }
  fi
  if path="$(resolve "$name")"; then
    RESOLVED+=("$path")
  else
    SKIPPED+=("$name (unresolved)")
  fi
done

if [[ ${#RESOLVED[@]} -eq 0 ]]; then
  printf '  ?? %s\n' "${SKIPPED[@]}" >&2
  die 3 "no files resolvable against --root=$ROOT" \
    "${#SKIPPED[@]} name(s) identified, none found on disk. Is --root pointing at the right project?"
fi

# ── Step 4: concat ──────────────────────────────────────────────────────────
out_tmp="$(mktemp)"
for p in "${RESOLVED[@]}"; do
  # Path relative to ROOT when it lives underneath it — basename alone is
  # ambiguous once recursion pulls in one index.ts per package.
  label="${p#"$ROOT"/}"
  printf '\n=== %s ===\n\n' "$label" >> "$out_tmp"
  cat "$p" >> "$out_tmp"
done
fi

bytes="$(wc -c < "$out_tmp")"
lines="$(wc -l < "$out_tmp")"

# ── Step 5: output ──────────────────────────────────────────────────────────
case "$OUTPUT" in
  clipboard)
    if command -v wl-copy &>/dev/null; then
      wl-copy < "$out_tmp"
    elif command -v xclip &>/dev/null; then
      xclip -selection clipboard < "$out_tmp"
    elif command -v pbcopy &>/dev/null; then
      pbcopy < "$out_tmp"
    else
      die 2 "no clipboard tool" "Install wl-clipboard, xclip, or use --output stdout."
    fi
    ;;
  stdout)
    cat "$out_tmp"
    ;;
  *)
    cp "$out_tmp" "$OUTPUT"
    ;;
esac

# ── Report (stderr so stdout-mode stays clean) ──────────────────────────────
{
  noun="files"; [[ "$TARGET" == "sessions" ]] && noun="sessions"
  echo "snap-extract: ${#RESOLVED[@]} $noun → $bytes bytes / $lines lines → $OUTPUT"
  for p in "${RESOLVED[@]}"; do printf '  ✓ %s\n' "$p"; done
  for s in "${SKIPPED[@]}"; do printf '  ✗ %s\n' "$s"; done
} >&2

# Rough token estimate: ~4 characters per token is the usual rule of thumb for
# code. It is the number that actually decides whether this fits in a context
# window, so it belongs in the notification more than the byte count does.
human_size="$(awk -v b="$bytes" 'BEGIN{ if (b<1024) printf "%d B", b;
  else if (b<1048576) printf "%.1f KB", b/1024; else printf "%.1f MB", b/1048576 }')"
approx_tokens="$(awk -v b="$bytes" 'BEGIN{ t=b/4;
  if (t<1000) printf "%d", t; else printf "%.0fk", t/1000 }')"
notify normal "snap-extract → ${OUTPUT}" \
  "${#RESOLVED[@]} ${noun} · ${human_size} · ~${approx_tokens} tokens"

rm -f "$out_tmp"
# Only clean up the screenshot we captured ourselves — a user-supplied
# --image is theirs, even when it lives in /tmp.
# Must be an `if`, not `[[ ... ]] && rm`: as the final statement under `set -e`
# a false test would make a perfectly successful run exit non-zero.
if [[ ${IMAGE_IS_TEMP:-0} -eq 1 ]]; then
  rm -f "$IMAGE"
fi
exit 0
exit 0
