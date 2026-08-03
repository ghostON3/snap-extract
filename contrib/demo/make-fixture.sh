#!/usr/bin/env bash
# Builds the throwaway repo that cli.tape records against, so the demo is
# reproducible on any machine rather than depending on the author's disk.
set -euo pipefail
D="${1:-/tmp/snapx-demo}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

rm -rf "$D"
mkdir -p "$D/demo-repo/packages/ui/src" "$D/demo-repo/packages/core/src" \
         "$D/demo-repo/packages/ui/node_modules/junk" "$D/bin"

cat > "$D/demo-repo/packages/ui/src/button.ts" <<'TS'
export type ButtonVariant = 'primary' | 'ghost'

export function button(variant: ButtonVariant = 'primary') {
  return { variant, role: 'button' }
}
TS
echo "export * from './button'" > "$D/demo-repo/packages/ui/src/index.ts"
cat > "$D/demo-repo/packages/core/src/clock.ts" <<'TS'
export interface Clock { now(): Date }

export const systemClock: Clock = { now: () => new Date() }
TS
echo "export const noise = 1" > "$D/demo-repo/packages/ui/node_modules/junk/index.ts"

ln -sf "$REPO/snap-extract.sh" "$D/bin/snap-extract.sh"
echo "fixture ready at $D"
