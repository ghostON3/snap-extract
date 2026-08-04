# Demo assets

Two demos, because they show different things.

## `cli.tape` → `assets/cli.gif`

Terminal-only, fully scripted, reproducible by anyone. Shows folder mode: a
flat read finding nothing, the error explaining why, then `-r` walking the tree
with `node_modules` pruned and every file labelled by its path.

```sh
# one-time fixture the tape expects
contrib/demo/make-fixture.sh
vhs contrib/demo/cli.tape
```

Needs [vhs](https://github.com/charmbracelet/vhs) and `ttyd`.

Rendering this is worth doing after behaviour changes — it caught a real bug
where a relative `--folder` path resolved nothing.

## `record-demo.sh` → `assets/demo.gif`

The screenshot flow, which cannot be scripted: it needs a real mouse drag.

```sh
contrib/demo/record-demo.sh --seconds 20
```

Select the region to record — include the corner where your notifications
appear — then perform:

1. Have an editor sidebar or a `tree` listing visible.
2. Press the leader key, then the project key.
3. Drag a rectangle over the filenames.
4. Paste into a text field so the result is visible.

Writes `assets/demo.mp4` (master) and `assets/demo.gif` (README). Keep it under
20 seconds; pass `--width 700 --fps 12` if the GIF lands over 10 MB.

## `render-public-demo.sh` → public README assets

Treat `assets/demo.mp4` as a private master: a desktop recording can expose
project names, source code, terminal history, browser chrome, or notifications.
The public render uses explicit time cuts, anonymizes the editor footage, crops
browser chrome, and adds the short product narrative used by the main README.

```sh
contrib/demo/render-public-demo.sh
```

It writes `assets/demo-public.mp4` and `assets/demo-public.gif` without changing
either original recording. Review representative full-resolution frames before
publishing whenever the source recording changes; crop coordinates and safe
time ranges are recording-specific.
