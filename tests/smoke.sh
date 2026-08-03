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
echo "alpha-index"   > "$TREE/alpha/src/index.ts"
echo "alpha-nested"  > "$TREE/alpha/src/nested/deep.ts"
echo "beta-index"    > "$TREE/beta/src/index.ts"
echo "beta-solo" > "$TREE/beta/src/solo.ts"
echo "should-not-appear" > "$TREE/beta/node_modules/junk/evil.ts"

run() { "$SCRIPT" "$@" --output stdout 2>/dev/null; }
count_files() { grep -c '^=== ' <<<"$1"; }

# ── folder mode, flat ──────────────────────────────────────────────────────
out="$(run --folder "$TREE/alpha/src" --ext .ts)"
[[ "$(count_files "$out")" == "1" ]] \
  && ok "flat folder: immediate children only" \
  || bad "flat folder" "expected 1 file, got $(count_files "$out")"

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

# ── explicit paths ─────────────────────────────────────────────────────────
out="$(run --paths "solo.ts" --root "$TREE" --ext .ts)"
grep -q "beta-solo" <<<"$out" \
  && ok "paths mode: resolves a name under --root" \
  || bad "paths mode" "did not resolve solo.ts"

# ── empty result exits non-zero ────────────────────────────────────────────
"$SCRIPT" --folder "$TREE/alpha" --ext ".nonexistent" --output stdout >/dev/null 2>&1
[[ $? -ne 0 ]] \
  && ok "no matches: exits non-zero" \
  || bad "no matches" "expected a non-zero exit"

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
else
  skip "auto-promote" "needs tesseract + imagemagick"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
