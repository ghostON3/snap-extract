#!/usr/bin/env bash
set -euo pipefail

# Turn the private dual-purpose screen recording into the short, silent demo
# embedded by the public README. The source files are inputs only: this script
# never rewrites demo.mp4 or demo.gif.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source_video="$repo_root/assets/demo.mp4"
public_video="$repo_root/assets/demo-public.mp4"
public_gif="$repo_root/assets/demo-public.gif"
font_regular=/usr/share/fonts/noto/NotoSans-Regular.ttf
font_bold=/usr/share/fonts/noto/NotoSans-Bold.ttf

for command_name in ffmpeg ffprobe; do
  command -v "$command_name" >/dev/null || {
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  }
done

[[ -f "$source_video" ]] || {
  printf 'Missing source recording: %s\n' "$source_video" >&2
  exit 1
}

for font_file in "$font_regular" "$font_bold"; do
  [[ -f "$font_file" ]] || {
    printf 'Missing font: %s\n' "$font_file" >&2
    exit 1
  }
done

render_dir=$(mktemp -d)
trap 'rm -rf -- "$render_dir"' EXIT

# Narrative rhythm: intro/hotkey -> anonymized selector motion -> clean browser
# paste -> outro. The private picker is omitted, the editor workspace is fully
# mosaicked, and source seconds 9.85-12.80 are deliberately absent so the
# internal-dashboard transition cannot leak into the public edit.
ffmpeg -hide_banner -y -i "$source_video" \
  -filter_complex "
    color=c=0x061218:s=1280x720:r=30:d=1.40,
      drawgrid=w=80:h=80:t=1:c=0x37E6D4@0.055,
      drawtext=fontfile=${font_bold}:text='Super + Shift + E':x=(w-text_w)/2:y=238:fontsize=60:fontcolor=0x37E6D4,
      drawtext=fontfile=${font_bold}:text='Point at files. Paste real context.':x=(w-text_w)/2:y=326:fontsize=37:fontcolor=white,
      drawtext=fontfile=${font_regular}:text='Local from capture to clipboard.':x=(w-text_w)/2:y=386:fontsize=24:fontcolor=0x9FB7C2,
      fade=t=in:st=0:d=0.24,fade=t=out:st=1.16:d=0.24,
      format=yuv420p[intro];

    [0:v]trim=start=7.55:end=9.85,setpts=PTS-STARTPTS,
      crop=3200:1500:400:180,scale=1152:540:flags=lanczos,
      scale=96:45:flags=area,scale=1152:540:flags=neighbor,boxblur=2:1,
      pad=1280:720:64:90:color=0x061218,fps=30,
      drawbox=x=88:y=18:w=430:h=54:c=0x082A34@0.94:t=fill,
      drawbox=x=88:y=18:w=6:h=54:c=0x37E6D4:t=fill,
      drawtext=fontfile=${font_bold}:text='1  Select the file tree':x=112:y=31:fontsize=25:fontcolor=white,
      drawbox=x=296:y=620:w=688:h=62:c=0x082A34@0.98:t=fill:enable='between(t,0.82,2.30)',
      drawbox=x=296:y=620:w=6:h=62:c=0x37E6D4:t=fill:enable='between(t,0.82,2.30)',
      drawtext=fontfile=${font_bold}:text='18 files • 78.9 KB • ~20k tokens — copied locally':x=(w-text_w)/2:y=638:fontsize=22:fontcolor=white:enable='between(t,0.82,2.30)',
      fade=t=in:st=0:d=0.18,fade=t=out:st=2.08:d=0.22,
      format=yuv420p[editor];

    [0:v]trim=start=12.80:end=21.55,setpts=(PTS-STARTPTS)/1.45,
      crop=3200:1500:320:390,scale=1152:540:flags=lanczos,
      pad=1280:720:64:90:color=0x061218,fps=30,
      drawbox=x=64:y=416:w=850:h=214:c=0xE8E8E8:t=fill,
      drawbox=x=88:y=322:w=306:h=82:c=0xF1F1F1:t=fill,
      drawbox=x=88:y=322:w=306:h=82:c=0xC8C8C8:t=2,
      drawbox=x=106:y=342:w=28:h=28:c=0x37E6D4:t=fill,
      drawtext=fontfile=${font_bold}:text='Source context':x=150:y=332:fontsize=18:fontcolor=0x202020,
      drawtext=fontfile=${font_regular}:text='18 files attached':x=150:y=360:fontsize=16:fontcolor=0x676767,
      drawbox=x=88:y=18:w=470:h=54:c=0x082A34@0.94:t=fill,
      drawbox=x=88:y=18:w=6:h=54:c=0x37E6D4:t=fill,
      drawtext=fontfile=${font_bold}:text='2  Paste complete context':x=112:y=31:fontsize=25:fontcolor=white,
      fade=t=in:st=0:d=0.18,fade=t=out:st=5.81:d=0.22,
      format=yuv420p[chat];

    color=c=0x061218:s=1280x720:r=30:d=1.30,
      drawgrid=w=80:h=80:t=1:c=0x37E6D4@0.055,
      drawtext=fontfile=${font_bold}:text='The screenshot is only the pointer.':x=(w-text_w)/2:y=270:fontsize=43:fontcolor=white,
      drawtext=fontfile=${font_regular}:text='Your source stays local.':x=(w-text_w)/2:y=346:fontsize=27:fontcolor=0x37E6D4,
      fade=t=in:st=0:d=0.22,fade=t=out:st=1.08:d=0.22,
      format=yuv420p[outro];

    [intro][editor][chat][outro]concat=n=4:v=1:a=0[outv]
  " \
  -map '[outv]' -an -c:v libx264 -preset slow -crf 20 \
  -profile:v high -level 4.1 -pix_fmt yuv420p -movflags +faststart \
  "$public_video"

# GIF: smaller README preview, same edit and no accidental source audio.
ffmpeg -hide_banner -y -i "$public_video" \
  -vf "fps=12,scale=800:-2:flags=lanczos,split[g0][g1];[g0]palettegen=max_colors=128:stats_mode=diff[p];[g1][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 "$public_gif"

printf 'Rendered %s (%ss)\n' "$public_video" \
  "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$public_video")"
printf 'Rendered %s\n' "$public_gif"
