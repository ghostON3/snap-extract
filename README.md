# snap-extract

**Screenshot a file tree → its contents land in your clipboard.**

Drag a box around your editor's sidebar. OCR reads the filenames, the script
reads those files from disk, concatenates them, and copies the result. Paste
into any chat input.

Everything runs locally. No cloud calls, no API keys.

```sh
snap-extract.sh --screenshot --root ~/projects/my-app --ext ".ts,.md"
```

## The idea

OCR on a file sidebar is unreliable — names get truncated with ellipses, narrow
fonts get mangled, files scroll out of view. So snap-extract doesn't trust it.

It only needs **one** filename to be read correctly. The moment a name resolves
to a real file under `--root`, the script discards the OCR list entirely and
re-reads that file's **directory** from disk, which is authoritative.

That inverts the problem. The screenshot stops being a *file list* and becomes a
*pointer to a folder*. Truncated names, misread characters and off-screen files
all stop mattering.

Every recognised name votes, so a screenshot spanning several directories yields
the union of them — not whichever one happened to sort first.

## Install

```sh
git clone https://github.com/ghostON3/snap-extract
cd snap-extract && chmod +x snap-extract.sh
```

Dependencies:

| Need                | Wayland                    | X11              |
| ------------------- | -------------------------- | ---------------- |
| screenshot          | `grim` + `slurp`           | `scrot`          |
| clipboard           | `wl-clipboard` (`wl-copy`) | `xclip`          |
| OCR                 | `tesseract` + a language pack             |
| preprocessing       | `imagemagick` — strongly recommended, see Backends |
| runtime             | `bash >= 4`, `python3` (vision backend only) |

Arch: `pacman -S grim slurp wl-clipboard tesseract tesseract-data-eng imagemagick`

## Modes

```sh
# Screenshot a file tree → clipboard
snap-extract.sh --screenshot --root ~/projects/my-app --ext ".ts,.md"

# Whole directory tree, no screenshot
snap-extract.sh --folder ~/projects/my-app/packages -r --ext ".ts,.json"

# Flat directory (immediate children only)
snap-extract.sh --folder ~/notes --ext .md

# Explicit paths
snap-extract.sh --paths "a.md,b.md" --root ~/notes

# Reuse an existing image instead of capturing
snap-extract.sh --image /tmp/shot.png --root ~/projects/my-app

# Print instead of touching the clipboard
snap-extract.sh --folder ~/notes --output stdout
```

## Options

| Flag | Default | Meaning |
| ---- | ------- | ------- |
| `--screenshot` / `--image F` / `--folder D` / `--paths "a,b"` | — | input mode (pick one) |
| `--root DIR` | `$PWD` | where filenames are resolved |
| `--ext ".ts,.md"` | `.md` | extensions to include |
| `-r`, `--recursive` | off | walk the whole tree, not just immediate children |
| `--max-depth N` | `8` | depth limit when recursing |
| `--prune "a,b"` | see below | directory names to skip when recursing |
| `--exclude "*.test.ts"` | — | glob filter; matches full path or basename |
| `--include "*.ts"` | — | keep only matches |
| `--output` | `clipboard` | `clipboard`, `stdout`, or a file path |
| `--backend` | `tesseract` | `tesseract` (fast) or `vision` (Ollama) |
| `--debug` | off | log identification and promotion decisions to stderr |

Pruned by default when recursing: `.git`, `node_modules`, `dist`, `build`,
`out`, `.next`, `.turbo`, `.svelte-kit`, `coverage`, `__pycache__`, `.venv`,
`venv`, `target`, `vendor`.

## Backends

- **`tesseract`** (default) — pure CPU OCR, ~1–4 s. Pulls tokens matching your
  `--ext` list out of the OCR'd text. Misses plenty; auto-promotion covers it.

  The image is normalised first, which matters more than it sounds. Tesseract
  expects large dark-on-light text; an editor sidebar on a dark theme is ~13px
  light-on-dark, and fed raw it drops the dot before the extension
  (`contract.ts` → `contractts`) so the extension filter rejects everything.
  snap-extract converts to grayscale, inverts when the background is dark,
  upscales 4× and sharpens before running OCR in single-block mode. Install
  ImageMagick — without it accuracy on real sidebars collapses.
- **`vision`** — `qwen3-vl:8b` via a local Ollama. 2–4 s on GPU, 60–300 s on
  CPU. Only worth it for semantic instructions. Prompt in `prompts/identify.txt`.

## Compositor keybind

Hyprland:

```
bind = SUPER SHIFT, E, exec, ~/snap-extract/snap-extract.sh --screenshot --root ~/projects/my-app --debug 2>/tmp/snap-extract.log
```

Press → drag over the file tree → paste with `Ctrl+V`.

Keep `--root` scoped to one project. Pointing it at `$HOME` makes every name
resolution a depth-8 `find` across your entire home directory: slow, and prone
to matching some unrelated `index.ts` in an archive folder.

## Known limits

- **Name collisions resolve to the first match.** `resolve_in_root_any_depth`
  takes whichever `find` hit comes back first, so with eight packages each
  holding an `index.ts`, a narrow `--root` matters.
- **`--prune` only applies when recursing.** Flat mode has nothing to prune.
- **No `.gitignore` awareness.** The prune list is a static default.
- **Wayland-first.** The X11 path (`scrot` + `xclip`) is written but lightly
  tested. macOS is not wired up.

If you want a mature repo-to-prompt packer with token counting and `.gitignore`
support, use [repomix](https://github.com/yamadashy/repomix) or
[gitingest](https://github.com/cyclotruc/gitingest). snap-extract exists for the
screenshot path — pointing at what's on screen instead of typing globs.

## License

MIT
