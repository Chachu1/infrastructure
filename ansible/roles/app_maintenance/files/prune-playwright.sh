#!/usr/bin/env bash
# Remove Playwright/Patchright browser revisions that no retained release
# references. Preserving revisions used by old releases keeps rollback working:
# deploy.yml skips `playwright install` when an old release's venv exists.
#
# Usage: prune-playwright.sh <app-root>

set -euo pipefail

app_root="${1:?usage: prune-playwright.sh <app-root>}"
cache="$app_root/.cache/ms-playwright"

if [ ! -d "$cache" ]; then
  echo "no Playwright cache at $cache; skipping"
  exit 0
fi

mapfile -t bjs < <(
  find "$app_root/releases" "$app_root/current" \
    -path '*/driver/package/browsers.json' 2>/dev/null
)

if [ "${#bjs[@]}" -eq 0 ]; then
  echo "no browsers.json in any retained release; skipping"
  exit 0
fi

keep=$(python3 - "${bjs[@]}" <<'PY'
import json
import sys

names = {"chromium", "chromium-headless-shell", "ffmpeg"}
revisions = set()

for path in sys.argv[1:]:
    try:
        data = json.load(open(path))
    except (OSError, ValueError):
        continue
    for browser in data.get("browsers", []):
        if browser.get("name") in names:
            revisions.add(str(browser["revision"]))

print(" ".join(sorted(revisions)))
PY
)

if [ -z "$keep" ]; then
  echo "no active browser revisions found; skipping"
  exit 0
fi

echo "keeping revisions: $keep"
cd "$cache"
for d in chromium-* chromium_headless_shell-* ffmpeg-*; do
  [ -e "$d" ] || continue
  rev=${d##*-}
  case " $keep " in
    *" $rev "*) ;;
    *)
      echo "removing $d"
      rm -rf -- "$d"
      ;;
  esac
done
