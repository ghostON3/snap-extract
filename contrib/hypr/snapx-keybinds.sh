#!/usr/bin/env bash
# snapx-keybinds.sh — turn a project registry into a Hyprland submap.
#
# Reads ~/.config/snap-extract/projects.conf and writes a generated Hyprland
# config with a leader key that opens a project menu:
#
#   SUPER+SHIFT+E        opens the menu (a notification lists the projects)
#     s                  screenshot a file tree inside "strojx"
#     SHIFT+s            copy the whole "strojx" tree, no screenshot
#     Escape / q         cancel
#
# Re-run after editing the registry. The generated file is overwritten every
# time, so edit the registry, never the output.
set -euo pipefail

REGISTRY="${SNAPX_REGISTRY:-$HOME/.config/snap-extract/projects.conf}"
OUTPUT="${SNAPX_OUTPUT:-$HOME/.config/hypr/conf.d/snap-extract.conf}"
LEADER="${SNAPX_LEADER:-SUPER SHIFT, E}"
MENU_SCRIPT="${SNAPX_MENU_SCRIPT:-$HOME/.config/snap-extract/snapx-menu.sh}"

# The tmux conversation binding is not a project — it is not scoped to a repo,
# so it cannot live in the registry. It gets one reserved key instead. Set
# SNAPX_TMUX_KEY to empty to leave it out entirely.
TMUX_KEY="${SNAPX_TMUX_KEY-t}"
# Defaults chosen to stay pasteable: a full transcript with tool output can run
# to megabytes, which is useless in a browser tab and slow to put on a clipboard.
TMUX_FLAGS="${SNAPX_TMUX_FLAGS:---turns 60 --tools summary}"
SCRIPT="${SNAPX_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/snap-extract.sh}"

[[ -f "$REGISTRY" ]] || {
  echo "no registry at $REGISTRY" >&2
  echo "copy contrib/hypr/projects.conf.example there and edit it" >&2
  exit 2
}
[[ -x "$SCRIPT" ]] || { echo "snap-extract.sh not executable at $SCRIPT" >&2; exit 2; }

expand_tilde() { case "$1" in "~"*) printf '%s' "${HOME}${1#\~}" ;; *) printf '%s' "$1" ;; esac; }

# Trim in pure bash. `echo "$x" | xargs` also strips quotes, which silently
# turned --exclude "*.test.ts" into an unquoted glob in the generated config.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

declare -a BINDS=() MENU=() WARNINGS=()
declare -A SEEN=()

# Claim the tmux key before the registry is read, so a project that wants the
# same letter gets the normal duplicate-key warning rather than silently
# shadowing a binding that was written later.
[[ -n "$TMUX_KEY" ]] && SEEN["$TMUX_KEY"]="tmux conversations"

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  [[ -z "${line//[[:space:]]/}" ]] && continue

  IFS='|' read -r key label path exts extra <<<"$line"
  key="$(trim "${key:-}")"
  label="$(trim "${label:-}")"
  path="$(trim "${path:-}")"
  exts="$(trim "${exts:-}")"
  extra="$(trim "${extra:-}")"

  [[ -n "$key" && -n "$path" ]] || { WARNINGS+=("skipped malformed line: $line"); continue; }
  [[ ${#key} -eq 1 ]] || { WARNINGS+=("key '$key' must be a single character — skipped"); continue; }
  [[ -z "${SEEN[$key]:-}" ]] || { WARNINGS+=("key '$key' already used by ${SEEN[$key]} — skipped $label"); continue; }

  path="$(expand_tilde "$path")"
  [[ -d "$path" ]] || WARNINGS+=("$label: $path does not exist (binding written anyway)")
  SEEN["$key"]="$label"
  [[ -n "$exts" ]] && exts="--ext \"$exts\""

  # `hyprctl dispatch submap reset` runs first so the menu closes before slurp
  # draws its overlay — otherwise you would be selecting a region on top of a
  # compositor still in submap mode. It also means one bind per action, rather
  # than relying on two binds for the same key both firing.
  BINDS+=("# $label")
  BINDS+=("bind = , $key, exec, hyprctl dispatch submap reset && $SCRIPT --screenshot --root '$path' $exts $extra --notify")
  BINDS+=("bind = SHIFT, $key, exec, hyprctl dispatch submap reset && $SCRIPT --folder '$path' -r $exts $extra --notify")
  MENU+=("$key  $label")
done < "$REGISTRY"

# tmux conversations: screenshot a tiled grid and copy the whole conversation
# behind every pane in it. SHIFT skips the screenshot and takes every live
# session. No --root, because these are resolved through tmux and the
# transcript store rather than through a project directory.
if [[ -n "$TMUX_KEY" ]]; then
  BINDS+=("# tmux conversations")
  BINDS+=("bind = , $TMUX_KEY, exec, hyprctl dispatch submap reset && $SCRIPT --screenshot --tmux $TMUX_FLAGS --notify")
  BINDS+=("bind = SHIFT, $TMUX_KEY, exec, hyprctl dispatch submap reset && $SCRIPT --all-sessions $TMUX_FLAGS --notify")
  MENU+=("$TMUX_KEY  tmux conversations")
  command -v tmux &>/dev/null || WARNINGS+=("tmux is not installed — the '$TMUX_KEY' binding will fail until it is")
fi

[[ ${#MENU[@]} -gt 0 ]] || { echo "registry has no usable entries" >&2; exit 2; }

# Hyprland fires only the FIRST bind registered for a key combination. Emitting
# `bind = LEADER, submap, snapx` plus `bind = LEADER, exec, notify-send ...`
# therefore enters the submap and never shows the menu — leaving you in a modal
# state with no feedback, which is indistinguishable from the keybind doing
# nothing at all. So the leader runs a single exec, and that script both shows
# the menu and dispatches the submap. A script also gets real newlines in the
# notification, which are impossible to quote cleanly inside a Hyprland config.
mkdir -p "$(dirname "$MENU_SCRIPT")"
{
  echo "#!/usr/bin/env bash"
  echo "# Generated by snapx-keybinds.sh — do not edit."
  echo "# Run this by hand to test the menu without touching the keyboard."
  echo "notify-send -a snap-extract -t 4000 'snap-extract — pick a project' \"\$(cat <<'MENU'"
  printf '%s\n' "${MENU[@]}"
  echo
  if [[ -n "$TMUX_KEY" ]]; then
    echo "SHIFT+key = whole tree  ($TMUX_KEY: all live sessions)"
  else
    echo "SHIFT+key = whole tree"
  fi
  echo "Esc = cancel"
  echo "MENU"
  echo ")\""
  echo "hyprctl dispatch submap snapx"
} > "$MENU_SCRIPT"
chmod +x "$MENU_SCRIPT"

mkdir -p "$(dirname "$OUTPUT")"
{
  echo "# Generated by snapx-keybinds.sh — do not edit."
  echo "# Source: $REGISTRY"
  echo "# Edit the registry and re-run the generator instead."
  echo
  echo "# One bind only — Hyprland runs just the first bind per key."
  echo "bind = $LEADER, exec, $MENU_SCRIPT"
  echo
  echo "submap = snapx"
  printf '%s\n' "${BINDS[@]}"
  echo
  echo "bind = , escape, submap, reset"
  echo "bind = , q, submap, reset"
  echo "submap = reset"
} > "$OUTPUT"

echo "wrote $OUTPUT (${#MENU[@]} projects)"
echo "wrote $MENU_SCRIPT — run it directly to test the menu"
for w in ${WARNINGS[@]+"${WARNINGS[@]}"}; do echo "  ! $w" >&2; done

# The file only takes effect once hyprland.conf sources it.
HYPRCONF="$HOME/.config/hypr/hyprland.conf"
if [[ -f "$HYPRCONF" ]] && ! grep -q "conf.d/snap-extract.conf" "$HYPRCONF"; then
  echo
  echo "Add this line to $HYPRCONF, then run: hyprctl reload"
  echo "  source = $OUTPUT"
fi
