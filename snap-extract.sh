#!/usr/bin/env bash
# snap-extract — screenshot → identify files → concat → clipboard.
#
# Backbone for the Tauri "Snap Extract" popup window. Also usable standalone
# from a Hyprland keybind or terminal. Stays sovereign — no cloud calls by
# default.
#
# BACKENDS for image → filename identification
#   tesseract  (default) Pure OCR on CPU, ~1–4 s per screenshot. Pulls strings
#              matching `--ext` extensions from the OCR'd text. Truncated
#              names ("05-editor-multivers…") are missed, BUT if ANY name
#              resolves against --root we auto-promote to folder mode and
#              read the whole directory — which is what you want most of
#              the time anyway.
#   vision     Ollama qwen3-vl:8b. Slow on CPU (60–300 s), ~2–4 s on GPU.
#              Reserve for semantic tasks (voice exclusion, "skip files
#              with TODO", etc.). On AMD machines: needs ROCm configured.
#   paths      Skip identification, use --paths explicitly.
#   folder     Skip identification, glob --folder.
#
# USAGE
#   snap-extract.sh --screenshot --root /proj            # grim+slurp → tesseract → folder auto-detect
#   snap-extract.sh --image /tmp/snap.png --root /proj   # use existing screenshot
#   snap-extract.sh --image X --backend vision           # force qwen3-vl
#   snap-extract.sh --folder /proj --ext .md             # manual folder mode
#   snap-extract.sh --folder /proj -r --ext .ts,.md      # whole tree (recursive)
#   snap-extract.sh --paths "a.md,b.md" --root /proj     # explicit paths
#   snap-extract.sh --image X --output stdout            # don't touch clipboard
#   snap-extract.sh --image X --exclude "book.md,*.tmp"  # drop matching files
#   snap-extract.sh --image X --root ~ --max-depth 8     # resolve names in nested folders
#
# EXIT CODES
#   0  ok
#   1  bad invocation
#   2  identification step failed
#   3  no files identified / readable

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
# Directories never worth concatenating — pruned in recursive folder mode.
PRUNE_DIRS=".git,node_modules,dist,build,out,.next,.turbo,.svelte-kit,coverage,__pycache__,.venv,venv,target,vendor"

usage() { sed -n '/^# /,/^$/p' "$0" | head -25; exit 1; }

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
    -h|--help)     usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

log() { [[ $DEBUG -eq 1 ]] && echo "[snap-extract] $*" >&2 || true; }

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
    echo "no screenshot tool (need grim+slurp or scrot)" >&2; exit 1
  fi
  [[ -s "$IMAGE" ]] || { echo "screenshot empty / cancelled" >&2; exit 1; }
  MODE="image"
fi

# ── Step 2a: identify file names via tesseract (fast, CPU) ─────────────────
identify_via_tesseract() {
  local img="$1"
  command -v tesseract &>/dev/null || { echo "tesseract not installed" >&2; return 2; }
  local raw
  raw="$(tesseract "$img" - 2>/dev/null)" || return 2
  # Build a regex from --ext (".md,.sh" → "\.md|\.sh") and extract tokens
  # that look like file names (basename + extension). Limit to plausible
  # name chars to avoid pulling whole sentences.
  local ext_regex
  ext_regex="$(echo "$EXTS" | sed -E 's/[, ]+/|/g; s/\./\\./g')"
  echo "$raw" | grep -oE "[A-Za-z0-9][A-Za-z0-9_.+-]{0,100}(${ext_regex})" | sort -u
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

declare -a FILES=()

# ── Shared collector ────────────────────────────────────────────────────────
# Every mode funnels through this: given a directory, emit the absolute path of
# every file matching --ext. Honours --recursive, --max-depth and --prune, so
# screenshot mode and folder mode expand a directory identically. Emitting
# absolute paths means resolve() passes them straight through.
declare -a PRUNE_EXPR=()
IFS=',' read -ra PRUNE_ARR <<< "$PRUNE_DIRS"
for d in "${PRUNE_ARR[@]}"; do
  d="$(echo "$d" | xargs)"
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
    ext="$(echo "$ext" | xargs)"
    [[ -z "$ext" ]] && continue
    if [[ $RECURSIVE -eq 1 && ${#PRUNE_EXPR[@]} -gt 0 ]]; then
      find "$dir" -maxdepth "$depth" \
        \( "${PRUNE_EXPR[@]}" \) -prune -o \
        -type f -name "*${ext}" -print 2>/dev/null
    else
      find "$dir" -maxdepth "$depth" -type f -name "*${ext}" -print 2>/dev/null
    fi
  done
}

resolve_in_root_any_depth() {
  local name="$1"
  [[ -f "$ROOT/$name" ]] && { echo "$ROOT/$name"; return 0; }
  [[ -d "$ROOT" ]] || return 1
  find "$ROOT" -maxdepth "$MAX_DEPTH" -type f -name "$name" -print -quit 2>/dev/null
}

case "$MODE" in
  image)
    [[ -f "$IMAGE" ]] || { echo "image not found: $IMAGE" >&2; exit 1; }
    log "identification on $IMAGE (backend=$BACKEND)"
    case "$BACKEND" in
      tesseract)
        raw="$(identify_via_tesseract "$IMAGE")" || { echo "tesseract failed" >&2; exit 2; }
        ;;
      vision)
        raw="$(identify_via_vision "$IMAGE")" || { echo "vision call failed" >&2; exit 2; }
        ;;
      *)
        echo "unknown backend: $BACKEND (use tesseract or vision)" >&2; exit 1
        ;;
    esac
    log "raw identification output:"
    log "$raw"
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

    # ── Auto-promote to folder mode ────────────────────────────────────────
    # OCR only has to get *one* name right — disk is authoritative for the
    # rest. Resolve every identified name, take the set of parent directories,
    # and expand each through the same collector folder mode uses. Every name
    # votes (not just the first to resolve), so a screenshot spanning several
    # directories yields their union instead of whichever sorted first.
    if [[ -d "$ROOT" ]]; then
      declare -a PROMOTE_DIRS=()
      for n in "${FILES[@]}"; do
        resolved_for_promote="$(resolve_in_root_any_depth "$n" || true)"
        [[ -n "$resolved_for_promote" && -f "$resolved_for_promote" ]] || continue
        d="$(dirname "$resolved_for_promote")"
        printf '%s\n' "${PROMOTE_DIRS[@]}" 2>/dev/null | grep -qxF "$d" && continue
        PROMOTE_DIRS+=("$d")
        log "auto-promote: $n → $d"
      done
      if [[ ${#PROMOTE_DIRS[@]} -gt 0 ]]; then
        FILES=()
        while IFS= read -r f; do
          [[ -n "$f" ]] && FILES+=("$f")
        done < <(
          for d in "${PROMOTE_DIRS[@]}"; do collect_folder "$d"; done | sort -u
        )
        # Deepest common ancestor of the promoted dirs — keeps labels readable
        # and gives resolve() a sane base when several dirs are in play.
        ROOT="${PROMOTE_DIRS[0]}"
        for d in "${PROMOTE_DIRS[@]}"; do
          while [[ "$d/" != "$ROOT/"* ]]; do
            ROOT="$(dirname "$ROOT")"
            [[ "$ROOT" == "/" ]] && break
          done
        done
        log "promoted ${#PROMOTE_DIRS[@]} dir(s) → ${#FILES[@]} files, root=$ROOT"
      fi
    fi
    ;;
  folder)
    [[ -d "$FOLDER" ]] || { echo "folder not found: $FOLDER" >&2; exit 1; }
    ROOT="${FOLDER%/}"
    while IFS= read -r f; do
      [[ -n "$f" ]] && FILES+=("$f")
    done < <(collect_folder "$ROOT" | sort -u)
    ;;
  paths)
    IFS=',' read -ra P <<< "$PATHS"
    for p in "${P[@]}"; do
      FILES+=("$(echo "$p" | xargs)")
    done
    ;;
  *)
    echo "must pass --screenshot, --image, --folder, or --paths" >&2
    usage
    ;;
esac

[[ ${#FILES[@]} -gt 0 ]] || { echo "no files identified" >&2; exit 3; }

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
    pat="$(echo "$pat" | xargs)"
    # shellcheck disable=SC2053
    [[ "$name" == $pat ]] && return 0
    # In recursive mode names are relative paths — let "*.lock" still match
    # "pkg/a/b.lock" without forcing the user to write "*/*.lock".
    # shellcheck disable=SC2053
    [[ "$(basename "$name")" == $pat ]] && return 0
  done
  return 1
}

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
    IFS=',' read -ra EXT_ARR <<< "$EXTS"
    ok=0
    for ext in "${EXT_ARR[@]}"; do
      [[ "$name" == *"$ext" ]] && ok=1 && break
    done
    [[ $ok -eq 0 ]] && { SKIPPED+=("$name (ext-miss)"); continue; }
  fi
  if path="$(resolve "$name")"; then
    RESOLVED+=("$path")
  else
    SKIPPED+=("$name (unresolved)")
  fi
done

if [[ ${#RESOLVED[@]} -eq 0 ]]; then
  echo "no files resolvable against --root=$ROOT" >&2
  printf '  ?? %s\n' "${SKIPPED[@]}" >&2
  exit 3
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
      echo "no clipboard tool found" >&2; exit 1
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
  echo "snap-extract: ${#RESOLVED[@]} files → $bytes bytes / $lines lines → $OUTPUT"
  for p in "${RESOLVED[@]}"; do printf '  ✓ %s\n' "$p"; done
  for s in "${SKIPPED[@]}"; do printf '  ✗ %s\n' "$s"; done
} >&2

rm -f "$out_tmp"
# Only clean up the screenshot we captured ourselves — a user-supplied
# --image is theirs, even when it lives in /tmp.
[[ ${IMAGE_IS_TEMP:-0} -eq 1 ]] && rm -f "$IMAGE"
exit 0
