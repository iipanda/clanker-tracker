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

## Install with an agent

Paste this into Claude Code or Codex on the Mac you want to track:

```text
Install Clanker Tracker: clone https://github.com/iipanda/clanker-tracker into ~/Developer/clanker-tracker
(or git pull it), run scripts/install.sh, and tell me what it printed and how to fix anything it stopped on.
```

[`scripts/install.sh`](scripts/install.sh) checks the requirements, builds the app (or downloads
the latest release if Swift isn't installed), installs it to `~/Applications`, and sets up tracking
for Codex and Claude Code. Nothing it installs is quarantined, so there's no Gatekeeper prompt.

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
| **Claude Code** | Claude Code reports `rate_limits` only to its status line command. The collector hooks into your status line (or sets one up) and saves them whenever they change. | While Claude Code is running. |

- **Codex**: only the main `codex` limit is tracked. The Spark (`codex_bengalfox`) and `premium`
  limits are ignored. The first launch reads the last 9 weeks of logs (about 20 s for ~20 GB);
  after that only new lines are read as files grow.
- **Claude Code**: set up the collector from **Settings → Data sources** (or with
  `--install-collector`). What it does depends on your status line:

  | Your status line | What the collector does |
  | --- | --- |
  | A shell script that reads `input=$(cat)` | Adds a marked block right after that line. The block saves `rate_limits` in the background and prints nothing, so your status line looks the same. A copy of the script is kept as `<script>.clanker-backup`. |
  | Any other command (`npx ccstatusline`, a Python script, a one-liner, …) | Points `statusLine` at `~/.claude/clanker-statusline.sh`, which saves the limits, then runs your command with the same input and prints its output unchanged. |
  | None | Points `statusLine` at the same script, which saves the limits and shows a simple status line: `clanker · Opus · 5h 12% · 7d 40%`. |

  Only the `statusLine` entry in `~/.claude/settings.json` is edited; the rest of the file stays
  byte-for-byte the same, and a backup is saved as `settings.json.clanker-backup`. Settings shows
  the exact change before you install. **Remove** (or `--remove-collector`) puts the previous
  `statusLine` back exactly (the managed script keeps a copy of it). The collector needs `jq`,
  which ships with macOS 15 and later. Changes apply to new Claude Code sessions.

Usage from other machines, or from claude.ai and Codex on the web, shows up at the next local
reading. Until then the app shows the last known value and how old it is.

## Install

Requires macOS 26 or later.

**Download**: grab `ClankerTracker-<version>.zip` from
[Releases](https://github.com/iipanda/clanker-tracker/releases), unzip it, and move
**ClankerTracker.app** to Applications. Builds aren't notarized by Apple yet, so the first time
you open it macOS says it can't verify the app: click **Done**, then **System Settings → Privacy &
Security → Open Anyway**. (Or run `xattr -dr com.apple.quarantine /Applications/ClankerTracker.app`.)

**Build from source** (needs Xcode 26 / Swift 6.2; no Gatekeeper prompt, since nothing is downloaded):

```sh
git clone https://github.com/iipanda/clanker-tracker.git
cd clanker-tracker
scripts/install.sh      # build, install, set up tracking; or scripts/build-app.sh to only build and install
```

Then:

1. Click the ring in the menu bar → **Settings…**
2. Under **Data sources**, click **Install collector** for Claude Code (open **What changes** first if you want to see the edit).
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
| `--install-collector` / `--remove-collector` | Sets up or removes the Claude Code collector (prints the settings.json change) |
| `--show-window` | Opens the main window at launch |

```sh
~/Applications/ClankerTracker.app/Contents/MacOS/ClankerTracker --dump
```

Set `CLANKER_TRACKER_DIR` to use a different data folder, e.g. for a clean backfill without touching
the real one.

### Releases

```sh
scripts/release.sh 0.2.0              # test, universal build, zip, tag v0.2.0, publish a GitHub release
DRY_RUN=1 scripts/release.sh 0.2.0    # build and zip only
```

Releases are ad-hoc signed for now. With an Apple Developer ID, set `DEVELOPER_ID` (the certificate
name) and `NOTARY_PROFILE` (from `xcrun notarytool store-credentials`) and the same script signs with
the hardened runtime, notarizes, and staples the app, so it opens without any warning.

### Layout

```
Sources/ClankerCore/      model, forecast math, log parsers, file tailing + FSEvents, status line hook,
                          notification rules. No UI. Covered by Tests/ClankerCoreTests.
Sources/ClankerTracker/   the app: status item, popover, main window, settings (AppKit + SwiftUI)
design/index.html         the design board the UI follows
scripts/build-app.sh      bundle, sign, install
scripts/install.sh        install + set up tracking (what the agent prompt runs)
scripts/release.sh        universal build, zip, GitHub release
```

### Data files

Everything lives in `~/Library/Application Support/ClankerTracker/`:

- `history.json`: every limit window seen, compressed to the readings where usage changed. It's a
  cache: delete it together with `state.json` to re-read the logs from scratch.
- `state.json`: how far into each log file the app has read.
- `claude/latest.json`, `claude/history.jsonl`: written by the collector.
