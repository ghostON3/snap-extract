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

> Keep each command on **one line**. Some terminals mangle a pasted multi-line
> command with backslash continuations — the continuation arrives as a literal
> character and the script sees it as an unknown argument.

`snap-extract.sh --help` prints the full option list.

## User flows

### 1. Screenshot a file tree → clipboard

The flagship flow. Point at what's on screen instead of typing globs.

```sh
snap-extract.sh --screenshot --root ~/projects/my-app --ext ".ts,.tsx"
```

The cursor becomes a **crosshair**. Drag a rectangle over your editor's file
tree, or click once on a window to select the whole thing. `Escape` cancels.
OCR reads the visible names; the moment one resolves on disk, that entire
directory is read instead. Then paste with `Ctrl+V`.

Add `--debug 2>/tmp/snap.log` when it misbehaves — the log shows exactly what
OCR read and which directories it promoted to.

### 2. A whole project or package tree → clipboard

No screenshot involved. This is the flow you want for "give the model my repo".

```sh
snap-extract.sh --folder ~/projects/my-app/packages -r --ext ".ts,.json"
```

Without `-r` you get only the immediate children of that directory — which for
a `packages/` folder containing nothing but subdirectories means no files at all.

### 3. One flat directory

For a folder of notes or chapters, where recursion would pull in noise.

```sh
snap-extract.sh --folder ~/notes --ext .md
```

### 4. Specific files by name

When you already know what you want. Names resolve under `--root`, so you don't
have to type full paths.

```sh
snap-extract.sh --paths "index.ts,config.ts" --root ~/projects/my-app
```

### 5. Preview before copying

Nothing touches the clipboard with `--output stdout`. Useful for checking the
size before pasting 400 KB into a chat box.

```sh
snap-extract.sh --folder ~/projects/my-app -r --ext .ts --output stdout | head -40
```

### 6. Write to a file

`--output` also takes a path, for building a context file you reuse.

```sh
snap-extract.sh --folder ~/notes -r --output /tmp/context.md
```

### 7. Re-run against an image you already have

Skips the capture step. Handy for iterating on `--ext` or `--exclude` without
re-dragging, and for debugging OCR on a saved screenshot.

```sh
snap-extract.sh --image /tmp/shot.png --root ~/projects/my-app --ext .ts
```

### 8. Semantic identification (Ollama)

An alternative to OCR when you need a model to interpret the screenshot rather
than transcribe it. Requires a local Ollama; slow on CPU.

```sh
snap-extract.sh --image /tmp/shot.png --root ~/proj --backend vision
```

### Filtering, in any flow

```sh
--exclude "*.test.ts,*.snap"   # drop matches (glob; path or basename)
--include "*.ts"               # keep only matches
--prune "node_modules,dist"    # directories to skip while recursing
--max-depth 3                  # how deep -r goes
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

## Project macros (Hyprland submap)

A leader key opens a project menu; one more key picks the project. Register the
projects you actually work in and each gets a two-key chord.

```sh
mkdir -p ~/.config/snap-extract
cp contrib/hypr/projects.conf.example ~/.config/snap-extract/projects.conf
$EDITOR ~/.config/snap-extract/projects.conf
contrib/hypr/snapx-keybinds.sh
```

The registry is one line per project:

```
# key | label | path | extensions [| extra flags]
s | strojx  | ~/projects/strojx           | .ts,.tsx,.json,.md | --exclude "*.test.ts"
e | elo v2  | ~/projects/elo-evolution-v2 | .ts,.tsx,.md
n | notes   | ~/notes                     | .md
```

The generator writes `~/.config/hypr/conf.d/snap-extract.conf`. Add
`source = ~/.config/hypr/conf.d/snap-extract.conf` to `hyprland.conf` once,
then `hyprctl reload`. Re-run the generator after editing the registry — the
output is overwritten every time, so edit the registry, never the output.

Then:

| Press | Result |
| --- | --- |
| `Super+Shift+E` | menu opens; a notification lists your projects |
| `s` | screenshot a file tree inside *strojx* |
| `Shift+s` | copy the whole *strojx* tree — no screenshot |
| `Escape` or `q` | cancel |

Each generated binding carries `--notify`, so you get a desktop notification
with the file count, size and a rough token estimate — without it a keybind
launch is silent and you cannot tell success from failure.

Everything is overridable by environment variable: `SNAPX_REGISTRY`,
`SNAPX_OUTPUT`, `SNAPX_LEADER` (default `SUPER SHIFT, E`), `SNAPX_SCRIPT`.

The leader is a single `exec` binding that shows the menu and enters the submap.
Hyprland runs only the **first** bind registered for a key combination, so a
separate `submap` bind plus a `notify-send` bind would enter the modal state and
never show the menu — looking exactly like the keybind doing nothing.

Run `~/.config/snap-extract/snapx-menu.sh` directly to test the menu without
touching the keyboard.

The generator refuses duplicate keys, rejects multi-character keys, and warns
about paths that do not exist rather than silently producing dead bindings.

## Compositor keybind (single project)

Hyprland:

```
bind = SUPER SHIFT, E, exec, ~/snap-extract/snap-extract.sh --screenshot --root ~/projects/my-app --debug 2>/tmp/snap-extract.log
```

Press → drag over the file tree → paste with `Ctrl+V`.

Keep `--root` scoped to one project. Pointing it at `$HOME` makes every name
resolution a depth-8 `find` across your entire home directory: slow, and prone
to matching some unrelated `index.ts` in an archive folder.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `unknown argument: E` (or similar) | a pasted multi-line command lost its `\` continuation | retype on one line |
| `nothing identified` after `--folder` | the directory holds only subdirectories | add `-r` |
| `nothing identified` after `--screenshot` | OCR read no name matching `--ext` | `--debug`, check the log; enlarge the region or the editor font |
| names read, but no `auto-promote` line | `--root` doesn't contain those files | point `--root` at the right project |
| wrong directory promoted | a same-named file elsewhere resolved first | narrow `--root` |
| garbage OCR on a dark theme | ImageMagick missing, so preprocessing was skipped | install `imagemagick` |

## Roadmap

Not implemented yet — listed so the gap is explicit rather than discovered.

- **`--dry-run`** — list the files and total size without reading contents, to
  check scope before filling the clipboard.
- **Token estimate** in the summary line, since the output usually goes into a
  model's context window.
- **`.gitignore` awareness** — currently the prune list is a static default.
- **Directory-name recognition.** OCR sees folder names too, but only file
  names participate in resolution today.
- **Instruction layer** — post-capture text like "skip the tests" applied to the
  file set, which is the one thing the `vision` backend is genuinely better at.
- **macOS support** (`screencapture` + `pbcopy`) and a verified X11 path; the
  X11 branch exists but is lightly tested.
- **Packaging** — an AUR package and a `snap-extract` binary on `PATH` instead
  of a cloned script.

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
