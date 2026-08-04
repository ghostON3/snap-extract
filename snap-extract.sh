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
    echo "snap-extract: pick an input mode — --screenshot, --folder, --paths, or --image" >&2
    echo >&2
    usage 2
    ;;
esac

if [[ ${#FILES[@]} -eq 0 ]]; then
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
  echo "snap-extract: ${#RESOLVED[@]} files → $bytes bytes / $lines lines → $OUTPUT"
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
  "${#RESOLVED[@]} files · ${human_size} · ~${approx_tokens} tokens"

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
