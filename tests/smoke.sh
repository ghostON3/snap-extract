#!/usr/bin/env bash
# smoke.sh — exercises every input mode against a throwaway tree.
# Clipboard is never touched; everything runs through --output stdout.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/snap-extract.sh"
PASS=0; FAIL=0

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mskip\033[0m %s (%s)\n' "$1" "$2"; }

# ── fixture ────────────────────────────────────────────────────────────────
TREE="$(mktemp -d)"
trap 'rm -rf "$TREE"' EXIT
mkdir -p "$TREE/alpha/src/nested" "$TREE/beta/src" "$TREE/beta/node_modules/junk"
echo "alpha-root"    > "$TREE/alpha/README.md"
echo "alpha-human"   > "$TREE/alpha/HUMAN.MD"
echo '{"enabled":true}' > "$TREE/alpha/config.json"
echo "alpha-index"   > "$TREE/alpha/src/index.ts"
echo "alpha-nested"  > "$TREE/alpha/src/nested/deep.ts"
echo "beta-index"    > "$TREE/beta/src/index.ts"
echo "beta-solo" > "$TREE/beta/src/solo.ts"
echo "beta-human" > "$TREE/beta/HUMAN.MD"
echo "should-not-appear" > "$TREE/beta/node_modules/junk/evil.ts"

run() { "$SCRIPT" "$@" --output stdout 2>/dev/null; }
count_files() { grep -c '^=== ' <<<"$1"; }

# ── folder mode, flat ──────────────────────────────────────────────────────
out="$(run --folder "$TREE/alpha/src" --ext .ts)"
[[ "$(count_files "$out")" == "1" ]] \
  && ok "flat folder: immediate children only" \
  || bad "flat folder" "expected 1 file, got $(count_files "$out")"

# Extension filters should follow editor/user expectations, not Unix filename
# casing. Uppercase HUMAN.MD must match a lowercase .md allowlist.
out="$(run --folder "$TREE/alpha" --ext ".md,.json")"
if grep -q "alpha-human" <<<"$out" && grep -q 'enabled' <<<"$out"; then
  ok "extensions: JSON and uppercase Markdown are included"
else
  bad "extensions" "expected HUMAN.MD and config.json in output"
fi

# ── folder mode, recursive ─────────────────────────────────────────────────
out="$(run --folder "$TREE/alpha" -r --ext .ts)"
[[ "$(count_files "$out")" == "2" ]] \
  && ok "recursive folder: descends into subdirectories" \
  || bad "recursive folder" "expected 2 files, got $(count_files "$out")"

# ── prune ──────────────────────────────────────────────────────────────────
out="$(run --folder "$TREE" -r --ext .ts)"
grep -q "should-not-appear" <<<"$out" \
  && bad "prune" "node_modules leaked into output" \
  || ok "prune: node_modules excluded when recursing"

# ── labels are relative and disambiguate same-named files ──────────────────
out="$(run --folder "$TREE" -r --ext .ts)"
if grep -q '^=== alpha/src/index.ts ===' <<<"$out" \
   && grep -q '^=== beta/src/index.ts ===' <<<"$out"; then
  ok "labels: same-named files stay distinct"
else
  bad "labels" "expected relative paths for both index.ts files"
fi

# ── exclude matches on basename even when nested ───────────────────────────
out="$(run --folder "$TREE" -r --ext .ts --exclude "deep.ts")"
grep -q "deep.ts" <<<"$out" \
  && bad "exclude" "deep.ts survived an explicit exclude" \
  || ok "exclude: basename glob matches nested paths"

# ── relative --folder path ─────────────────────────────────────────────────
# Regression: collection emits absolute paths, resolve() looked names up as
# "$ROOT/$name". With a relative --folder every file came back unresolved.
out="$(cd "$TREE" && "$SCRIPT" --folder alpha -r --ext .ts --output stdout 2>/dev/null)"
[[ "$(count_files "$out")" == "2" ]] \
  && ok "relative --folder path resolves" \
  || bad "relative --folder" "expected 2 files, got $(count_files "$out")"

# ── explicit paths ─────────────────────────────────────────────────────────
out="$(run --paths "solo.ts" --root "$TREE" --ext .ts)"
grep -q "beta-solo" <<<"$out" \
  && ok "paths mode: resolves a name under --root" \
  || bad "paths mode" "did not resolve solo.ts"

out="$(run --paths "alpha/HUMAN.MD" --root "$TREE" --ext .md)"
grep -q "alpha-human" <<<"$out" \
  && ok "paths mode: extension matching is case-insensitive" \
  || bad "paths mode case" "HUMAN.MD was rejected by the .md allowlist"

# ── empty result exits non-zero ────────────────────────────────────────────
"$SCRIPT" --folder "$TREE/alpha" --ext ".nonexistent" --output stdout >/dev/null 2>&1
[[ $? -ne 0 ]] \
  && ok "no matches: exits non-zero" \
  || bad "no matches" "expected a non-zero exit"

# ── a successful run exits zero ────────────────────────────────────────────
# Regression: `[[ ... ]] && rm` as the final statement under `set -e` made
# every successful non-image run exit 1.
"$SCRIPT" --folder "$TREE/alpha/src" --ext .ts --output stdout >/dev/null 2>&1
[[ $? -eq 0 ]] \
  && ok "success: exits zero" \
  || bad "success exit code" "a run that produced files still exited non-zero"

# ── help and invocation errors ─────────────────────────────────────────────
help_out="$("$SCRIPT" --help 2>/dev/null)"; help_rc=$?
if [[ $help_rc -eq 0 ]] && grep -q "INPUT MODES" <<<"$help_out"; then
  ok "--help: prints usage to stdout and exits zero"
else
  bad "--help" "exit $help_rc, and/or usage text missing"
fi

"$SCRIPT" --not-a-flag >/dev/null 2>&1
[[ $? -eq 2 ]] \
  && ok "bad argument: exits 2" \
  || bad "bad argument" "expected exit 2"

err="$("$SCRIPT" --not-a-flag 2>&1 >/dev/null)"
grep -q "unknown argument" <<<"$err" \
  && ok "bad argument: names the offending flag on stderr" \
  || bad "bad argument" "stderr did not name the argument"

# The header comments must never be the help text again — they used to leak
# internal notes to anyone who mistyped a flag.
grep -q "Backbone for the Tauri" <<<"$help_out" \
  && bad "help text" "help is dumping the script's own header comments" \
  || ok "help: does not dump internal header comments"

# ── auto-promote (needs OCR + an image renderer) ───────────────────────────
if command -v tesseract &>/dev/null && command -v magick &>/dev/null; then
  IMG="$TREE/shot.png"
  magick -size 640x160 xc:white -pointsize 34 -fill black \
    -annotate +25+55 "solo.ts" -annotate +25+110 "deep.ts" "$IMG" 2>/dev/null
  out="$(run --image "$IMG" --root "$TREE" --ext .ts)"
  # deep.ts lives in alpha/src/nested, solo.ts in beta/src -> union of both
  if grep -q "alpha/src/nested/deep.ts" <<<"$out" \
     && grep -q "beta/src/solo.ts" <<<"$out"; then
    ok "auto-promote: unions every directory a recognised name points at"
  else
    bad "auto-promote" "expected files from both directories:"$'\n'"$(grep '^=== ' <<<"$out")"
  fi
  [[ -f "$IMG" ]] \
    && ok "cleanup: a user-supplied --image is not deleted" \
    || bad "cleanup" "the script deleted an image it did not create"

  # A common basename can exist throughout a monorepo. A uniquely recognised
  # neighbor should anchor it to the right directory instead of promoting the
  # first unrelated match returned by find.
  ANCHORED="$TREE/anchored.png"
  magick -size 640x160 xc:white -pointsize 34 -fill black \
    -annotate +25+55 "HUMAN.MD" -annotate +25+110 "config.json" "$ANCHORED" 2>/dev/null
  out="$(run --image "$ANCHORED" --root "$TREE" --ext ".md,.json")"
  if grep -q "alpha-human" <<<"$out" && ! grep -q "beta-human" <<<"$out"; then
    ok "auto-promote: unique neighbor anchors a duplicate basename"
  else
    bad "auto-promote duplicate" "HUMAN.MD was promoted from the wrong directory"
  fi

  # ── dark theme: the case that made this unusable in practice ─────────────
  # 13px light-on-dark is what every dark editor theme actually looks like.
  # Un-preprocessed, tesseract drops the dot before the extension
  # ("solo.ts" -> "solots") and the extension regex rejects everything.
  DARK="$TREE/dark.png"
  magick -size 260x120 xc:"#1e1e1e" -fill "#cccccc" -pointsize 13 \
    -annotate +20+40 "solo.ts" -annotate +20+70 "index.ts" "$DARK" 2>/dev/null
  out="$(run --image "$DARK" --root "$TREE/beta" --ext .ts)"
  [[ "$(count_files "$out")" -ge 2 ]] \
    && ok "dark theme: small light-on-dark text is recognised" \
    || bad "dark theme" "expected >=2 files from beta/src, got $(count_files "$out")"
else
  skip "auto-promote" "needs tesseract + imagemagick"
fi

# ── tmux conversation mode ─────────────────────────────────────────────────
# Driven entirely off a synthetic transcript store so it needs no tmux server
# and touches none of the real ones. Names are resolved by the store-slug path,
# which is the branch that matters most anyway: it is what recovers a session
# whose tmux pane is already gone.
if command -v python3 &>/dev/null; then
  STORE="$TREE/store"
  SLUG="-tmp-fixture-alphaproj"
  mkdir -p "$STORE/projects/$SLUG"
  NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  OLD="2020-01-01T00:00:00.000Z"
  TRANSCRIPT="$STORE/projects/$SLUG/aaaa.jsonl"
  {
    printf '{"type":"user","cwd":"/tmp/fixture/alphaproj","gitBranch":"feat/x","timestamp":"%s","message":{"content":"ancient question"}}\n' "$OLD"
    printf '{"type":"assistant","cwd":"/tmp/fixture/alphaproj","gitBranch":"feat/x","timestamp":"%s","message":{"content":[{"type":"text","text":"SENTINEL_REPLY"},{"type":"thinking","thinking":"SENTINEL_THOUGHT"}]}}\n' "$NOW"
    printf '{"type":"assistant","cwd":"/tmp/fixture/alphaproj","timestamp":"%s","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"SENTINEL_CMD --flag"}}]}}\n' "$NOW"
    printf '{"type":"user","cwd":"/tmp/fixture/alphaproj","timestamp":"%s","message":{"content":[{"type":"tool_result","content":"SENTINEL_OUTPUT"}]}}\n' "$NOW"
    printf '{"type":"user","isSidechain":true,"cwd":"/tmp/fixture/alphaproj","timestamp":"%s","message":{"content":"SENTINEL_SIDECHAIN"}}\n' "$NOW"
    printf '{"type":"user","cwd":"/tmp/fixture/alphaproj","timestamp":"%s","message":{"content":"key is sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUV"}}\n' "$NOW"
  } > "$TRANSCRIPT"

  sess() { "$SCRIPT" --store "$STORE" --output stdout "$@" 2>/dev/null; }

  out="$(sess --sessions alphaproj)"
  if grep -q "SENTINEL_REPLY" <<<"$out" && grep -q "cwd: /tmp/fixture/alphaproj" <<<"$out"; then
    ok "sessions: a dead session resolves through its transcript slug"
  else
    bad "sessions: slug resolution" "no transcript content in output"
  fi

  grep -q "branch: feat/x" <<<"$out" \
    && ok "sessions: branch is read back out of the transcript" \
    || bad "sessions: branch" "gitBranch missing from the header"

  # Tool calls are one summary line by default: enough to follow what happened
  # without dragging the tool's entire output into the paste.
  if grep -q "SENTINEL_CMD" <<<"$out" && ! grep -q "SENTINEL_OUTPUT" <<<"$out"; then
    ok "sessions: --tools summary keeps the call, drops the output"
  else
    bad "sessions: --tools summary" "expected the command but not its result"
  fi

  out="$(sess --sessions alphaproj --tools full)"
  grep -q "SENTINEL_OUTPUT" <<<"$out" \
    && ok "sessions: --tools full includes tool results" \
    || bad "sessions: --tools full" "tool result missing"

  out="$(sess --sessions alphaproj --tools none)"
  ! grep -q "SENTINEL_CMD" <<<"$out" \
    && ok "sessions: --tools none drops tool calls entirely" \
    || bad "sessions: --tools none" "tool call survived"

  out="$(sess --sessions alphaproj)"
  ! grep -q "SENTINEL_THOUGHT" <<<"$out" \
    && ok "sessions: thinking is excluded by default" \
    || bad "sessions: thinking" "thinking block leaked into the bundle"

  out="$(sess --sessions alphaproj --thinking)"
  grep -q "SENTINEL_THOUGHT" <<<"$out" \
    && ok "sessions: --thinking includes it" \
    || bad "sessions: --thinking" "thinking block missing"

  out="$(sess --sessions alphaproj)"
  ! grep -q "SENTINEL_SIDECHAIN" <<<"$out" \
    && ok "sessions: sidechains are excluded by default" \
    || bad "sessions: sidechains" "sidechain leaked into the bundle"

  # A transcript is a recording of someone's own machine. Anything that looks
  # like a credential must not survive into something headed for a browser tab.
  out="$(sess --sessions alphaproj)"
  if ! grep -q "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUV" <<<"$out" && grep -q "sk-ant-<redacted>" <<<"$out"; then
    ok "sessions: secrets are masked by default"
  else
    bad "sessions: redaction" "an API key survived into the output"
  fi

  out="$(sess --sessions alphaproj --no-redact)"
  grep -q "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUV" <<<"$out" \
    && ok "sessions: --no-redact is honoured" \
    || bad "sessions: --no-redact" "still masked after opting out"

  out="$(sess --sessions alphaproj --turns 1)"
  [[ "$(grep -c '^--- ' <<<"$out")" == "1" ]] \
    && ok "sessions: --turns keeps only the last N messages" \
    || bad "sessions: --turns" "expected 1 message, got $(grep -c '^--- ' <<<"$out")"

  out="$(sess --sessions alphaproj --since 1h)"
  if grep -q "SENTINEL_REPLY" <<<"$out" && ! grep -q "ancient question" <<<"$out"; then
    ok "sessions: --since drops messages older than the window"
  else
    bad "sessions: --since" "time filter did not apply"
  fi

  sess --sessions alphaproj --format json | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)[0]["cwd"]=="/tmp/fixture/alphaproj" else 1)' \
    && ok "sessions: --format json emits parseable JSON" \
    || bad "sessions: --format json" "output did not parse"

  sess --sessions alphaproj --format json --max-bytes 40 | python3 -c 'import json,sys; json.load(sys.stdin)' \
    && ok "sessions: --max-bytes leaves JSON parseable" \
    || bad "sessions: --max-bytes json" "truncation produced invalid JSON"

  # Transcripts are keyed by directory, so several names can land on one file.
  # It must appear once, not once per name.
  out="$(sess --sessions "alphaproj,alphapro")"
  [[ "$(grep -c '^=== session' <<<"$out")" == "1" ]] \
    && ok "sessions: one transcript is emitted once, not once per name" \
    || bad "sessions: dedupe" "got $(grep -c '^=== session' <<<"$out") sections for one transcript"

  grep -q "also open in:" <<<"$out" \
    && ok "sessions: the deduped names are still recorded as aliases" \
    || bad "sessions: aliases" "collapsed names vanished from the output"

  # "claude" appears in every pane's status line; it must never fuzzy-match.
  mkdir -p "$STORE/projects/-tmp-fixture-claudeproj"
  cp "$TRANSCRIPT" "$STORE/projects/-tmp-fixture-claudeproj/bbbb.jsonl"
  "$SCRIPT" --store "$STORE" --sessions "claude" --output stdout &>/dev/null
  [[ $? -ne 0 ]] \
    && ok "sessions: status-bar chrome does not fuzzy-match a session" \
    || bad "sessions: chrome" "the bare word 'claude' pulled in a session"

  "$SCRIPT" --store "$STORE" --sessions alphaproj --list &>/dev/null \
    && ok "sessions: --list exits zero" \
    || bad "sessions: --list" "non-zero exit"

  "$SCRIPT" --store "$STORE" --sessions "definitely-not-a-session-xyz" --output stdout &>/dev/null
  [[ $? -eq 3 ]] \
    && ok "sessions: an unresolvable name exits 3" \
    || bad "sessions: unresolvable" "expected exit 3"
else
  skip "tmux conversation mode" "needs python3"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
