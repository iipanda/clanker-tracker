# Clanker Tracker

**A macOS menu bar app that tells you whether your Claude Code and Codex limits will last until they reset.**

It reads the limit data both tools already leave on your Mac, shows how much of each limit you've
used, projects your current pace forward, and warns you before you run out. Everything stays local:
no accounts, no servers, no network requests.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/popover-dark.png">
    <img src="docs/popover-light.png" width="320" alt="Menu bar dropdown showing Claude Code 5-hour and weekly limits and the Codex weekly limit, each with a bar, a status and a reset time">
  </picture>
</p>

## What it shows

- **Menu bar icon**: a ring that fills with whichever limit is closest to running out, plus its
  percentage. It stays monochrome like other menu bar icons, turns amber when your pace would hit
  100% before the reset, and switches to a red countdown to the reset once you hit the limit.
- **Dropdown**: every limit at a glance, with used %, "Runs out ~15:02" or "On track", and when it resets.
- **App window**: per tool, a burn chart of the current window (recorded usage, projection at your
  current pace, and an even-pace line), pace vs. sustainable pace, forecast details, and how full
  your recent weekly windows got before they reset.
- **Notifications**: once per window when your pace would run out before the reset, when usage
  passes a threshold (80% by default), and optionally when a limit resets.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/overview-dark.png">
  <img src="docs/overview-light.png" alt="Overview with a Claude Code card at 72% that runs out in 42 minutes, a Codex card at 54% on track, and bars for recent weekly windows">
</picture>

<sub>Screenshots use the sample data from <code>--demo</code>.</sub>

## How the forecast works

For the current window of each limit:

- **Pace**: how much the usage grew over the last hour (5-hour limits) or last 6 hours (weekly
  limits), in % per hour.
- **Runs out**: `remaining % ÷ pace`, added to now. If that lands before the reset, the limit
  shows amber.
- **Sustainable**: `remaining % ÷ hours until reset`, the pace that would land exactly on 100% at the reset.

The projection assumes you keep your recent pace without breaks, so right after a busy stretch
it's on the pessimistic side and it relaxes as idle hours drop out of the lookback.

## Where the data comes from

| Tool | Source | Updates |
| --- | --- | --- |
| **Codex** | Every model response writes a `token_count` event with `rate_limits` (the server's `used_percent`, window length and `resets_at`) to `~/.codex/sessions/**/rollout-*.jsonl`. | Within a second or two of each Codex response on this Mac. |
| **Claude Code** | Claude Code reports `rate_limits` only to its status line command. A small marked block in your status line script saves them whenever they change. | While Claude Code is running. |

- **Codex**: only the main `codex` limit is tracked. The Spark (`codex_bengalfox`) and `premium`
  limits are ignored. The first launch reads the last 9 weeks of logs (about 20 s for ~20 GB);
  after that only new lines are read as files grow.
- **Claude Code**: install the collector from **Settings → Data sources** (or with
  `--install-collector`). It adds this block right after `input=$(cat)` in the script named by
  `statusLine` in `~/.claude/settings.json`:

  ```sh
  # >>> clanker-tracker >>>
  ( d="${CLANKER_TRACKER_DIR:-$HOME/Library/Application Support/ClankerTracker}/claude"
    [ -d "$d" ] || exit 0
    rl=$(printf '%s' "$input" | jq -c '.rate_limits // empty' 2>/dev/null); [ -n "$rl" ] || exit 0
    ...
  ) </dev/null >/dev/null 2>&1 &
  # <<< clanker-tracker <<<
  ```

  It runs in the background with all output discarded, so your status line prints exactly what it
  did before. The original script is kept as `<script>.clanker-backup`, and **Remove** (or
  `--remove-collector`) takes the block out again. It needs `jq`.

Usage from other machines, or from claude.ai and Codex on the web, shows up at the next local
reading. Until then the app shows the last known value and how old it is.

## Install

Requires macOS 26 and Xcode 26 (Swift 6.2).

```sh
git clone https://github.com/iipanda/clanker-tracker.git
cd clanker-tracker
scripts/build-app.sh
```

This builds a release, signs it, installs it to `~/Applications/ClankerTracker.app`, and opens it.
Then:

1. Click the ring in the menu bar → **Settings…**
2. Under **Data sources**, click **Install collector** for Claude Code.
3. Allow notifications when macOS asks, and turn on **Open at login** if you want it always running.

> [!TIP]
> Rebuilding changes the ad-hoc signature, and macOS may then forget the notification and login-item
> permissions. To keep them, create a code-signing certificate named "Clanker Dev" in Keychain
> Access (Certificate Assistant → Create a Certificate → type *Code Signing*) and build with
> `CODESIGN_ID="Clanker Dev" scripts/build-app.sh`.

## Development

```sh
swift test                       # core logic: forecasts, parsers, file tailing, hook, notifications
INSTALL=0 scripts/build-app.sh   # build build/ClankerTracker.app without installing
open Package.swift               # work in Xcode
```

The binary takes a few flags that help while developing:

| Flag | What it does |
| --- | --- |
| `--dump` | Reads everything once and prints the current limits as JSON |
| `--demo` | Runs with the sample data from `design/index.html` |
| `--snapshot <dir>` | Renders the dropdown and window panes to PNGs (combine with `--demo`) |
| `--install-collector` / `--remove-collector` | Adds or removes the Claude Code status line block |
| `--show-window` | Opens the main window at launch |

```sh
~/Applications/ClankerTracker.app/Contents/MacOS/ClankerTracker --dump
```

Set `CLANKER_TRACKER_DIR` to use a different data folder, e.g. for a clean backfill without touching
the real one.

### Layout

```
Sources/ClankerCore/      model, forecast math, log parsers, file tailing + FSEvents, status line hook,
                          notification rules. No UI. Covered by Tests/ClankerCoreTests.
Sources/ClankerTracker/   the app: status item, popover, main window, settings (AppKit + SwiftUI)
design/index.html         the design board the UI follows
scripts/build-app.sh      bundle, sign, install
```

### Data files

Everything lives in `~/Library/Application Support/ClankerTracker/`:

- `history.json`: every limit window seen, compressed to the readings where usage changed. It's a
  cache: delete it together with `state.json` to re-read the logs from scratch.
- `state.json`: how far into each log file the app has read.
- `claude/latest.json`, `claude/history.jsonl`: written by the status line block.
