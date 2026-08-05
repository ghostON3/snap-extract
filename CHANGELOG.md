# Changelog

All notable changes to snap-extract are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file starts partway through the project's life. There are no tagged
releases yet, so changes made before it existed are only in the git history —
each one landed as a numbered pull request (`#1`–`#14`).

## [Unreleased]

### Added

- tmux conversation mode: point a screenshot at a tiled tmux grid and copy the
  full conversation behind every pane in it. Session names are read off the
  status bars, resolved to each pane's working directory, and the Claude Code
  transcript filed under that directory is read from disk — so a truncated
  status line costs nothing, exactly as a truncated filename already did.
  (`--tmux`, `--sessions`, `--all-sessions`, `--list`)
- Scope controls for those bundles, since a full transcript with tool output
  runs to megabytes and cannot be pasted anywhere useful: `--turns`, `--since`,
  `--tools full|summary|none`, `--thinking`, `--sidechains`, `--max-bytes`.
- Output shapes for downstream tools: `--format markdown|xml|json`.
- Secret masking, on by default, for API keys, tokens and private-key blocks.
  Transcripts record someone working on their own machine, which the file modes
  never did. `--no-redact` opts out; `--redact` adds patterns.
- Scrollback fallback for panes with no transcript — a plain shell, or a
  session older than the transcript store. Lossy and ANSI-stripped, but a
  silently dropped pane reads as "there was nothing there".
  (`--fallback`, `--scrollback`)
- `--store` to point at a non-default transcript location, and
  `--all-transcripts` to take every transcript for a directory rather than the
  newest one.
- `--ignore`, to extend the list of status-bar words barred from fuzzy-matching
  a session name.
- Hyprland bindings for the new mode, on a reserved `t` key: `t` screenshots a
  tmux grid, `Shift+t` takes every live session. Configurable through
  `SNAPX_TMUX_KEY` and `SNAPX_TMUX_FLAGS`.
- 19 smoke tests covering the new mode, run against a synthetic transcript
  store so they need neither a tmux server nor the real one.

### Notes

- Session mode needs `python3`, and `tmux` for anything but `--store`-only
  resolution. The file modes are unchanged and still need neither.
