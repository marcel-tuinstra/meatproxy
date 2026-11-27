# Setting up Meatproxy

Everything you need to get Meatproxy running and to switch on its factories and Server room. The short version is in
the [README](README.md).

## 1. Build and install

You need macOS 15 or newer and Xcode 26 (or just the Command Line Tools with Swift 6). There is no download and no
App Store version. You build it yourself, so Gatekeeper has nothing to complain about.

```bash
git clone https://github.com/marcel-tuinstra/meatproxy.git
cd meatproxy
scripts/make-app.sh
```

`make-app.sh` builds `build/Meatproxy.app` (ad-hoc signed, not notarised) and installs it in `/Applications`. A
running copy is closed first and opened again afterwards. Run it again after every `git pull`.

- `MEATPROXY_INSTALL=0 scripts/make-app.sh` only builds.
- `swift run Meatproxy` runs it straight from the package, without the app bundle. Real notifications (with the icon
  and their buttons) and *Open at login* (Settings › General, through the Mac's own Login Items) only work from the
  bundle.

## 2. First start

Meatproxy reads your sessions in `~/.claude/projects` (Claude Code) and `~/.codex/sessions` (Codex) and shows what it
finds every few seconds. Nothing needs setting up.

- **Take the walk:** a one-minute tour of the campus. **?** explains every key and every thing that moves.
- **Floors:** every folder under `~/Projects/<folder>` with a session in the last 8 hours is a floor. Sessions
  elsewhere go to their git root. Loose chats (your home folder, scratch folders) share one floor, *Chats*. A floor
  leaves its tower 8 hours after its last session. Pin a project (the pin in its panel, or Settings › Projects) to
  keep it.
- **Getting around:** click to fly somewhere, scroll or pinch to zoom, drag to pan. `Esc` or **Up** goes one level
  up. `N` flies to the next thing that waits for you. ⌘K searches, ⌘J opens the terminal, ⌘L shows the status
  layer, ⌘1 is the campus, ⌘2 is the Server room and ⌘, opens Settings. Right-click (or ⌃-click) anything for
  what you can do with it. Settings › General has *Text size: Larger*, and a switch for the single-key shortcuts
  (`N`, `1`, `2`, `?`) if they get in the way of voice control.

Want to look around without your own data? `swift run Meatproxy --fixture` shows a made-up campus with a demo
factory. Answering there touches nothing real.

## 3. Factories

A project becomes a factory when you switch it on: the switch at the top of its panel, or Settings › Projects (also
for a folder that is not on the campus right now). Switching it on changes nothing in the project.

1. **Starter files.** Meatproxy offers the files a CEO needs in `factory/`: the charter, the playbook, your mandate and
   the contract. You see each file first; it writes only the ones you tick, and never replaces one.
2. **The allowlist.** The CEO runs headless with the project's own `.claude/settings.json`: what it may run (tests,
   git) and nothing else. Without one it can do very little, and the card says so. Meatproxy can propose one.
3. **The mandate** (CEO tab): what the CEO may do on its own, item by item (ask, tell you afterwards, or never), and
   its team: how many developers, testers, designers and so on may work at once.
4. **The heartbeat.** Meatproxy wakes the CEO itself, with no scheduled tasks in Claude or ChatGPT: on its rhythm
   (weekdays at 07:10 by default), three minutes after you answer, on **Run now**, and when CI on `main` fails (through
   your own `gh`). Sentry and Tracker can wake it too (see 5).

Guardrails, so a factory does not burn through your plan: at most 6 automatic runs a day, 20 minutes between runs,
60 turns and 45 minutes per run, an optional daily cap at API prices, and a hold after repeated CI or Sentry wakes.
**Run now** is yours and skips them. **Pause all factories** stops everything. By default the heartbeat only beats
while the app runs. *Heartbeat when closed* (Settings) installs a launch agent that checks every five minutes.

**What a CEO asks you** shows under Needs you: a yes/no question, a to-do only you can do (with the steps and
**Done** / **Not now**), or finished work that waits for your release. Work on shared infrastructure (a CI runner,
a server) is a to-do for DevOps: **Send to DevOps** hands it to the Server room's DevOps agent, on the runtime you set
in Settings › Server room. **Release now** writes your own release, which
the CEO ships at its next run, even when your mandate keeps shipping off.

The files, their formats and who writes what are in the factory contract: [docs/contracts/factory.md](docs/contracts/factory.md).

## 4. The Server room

Settings › Server room: add a server as you would type it after `ssh` (`user@host` or a `Host` from `~/.ssh/config`),
with a name and a kind. Meatproxy checks it every minute with `ssh -o BatchMode=yes`: with your own keys and agent,
never with a password, and with normal host-key checking. A server is added only after a test login without a
password. If that fails, it says why (for a missing key: `ssh-copy-id`).

- **Checks:** load, disk and memory by default (a warning from 90% disk, load 1.5 per core or less than 10% free
  memory), or a command of your own (exit 0 ok, 1 warning, anything else down).
- **Sites:** public addresses served from a server, checked every five minutes for an answer and a valid certificate.
- **Alerts:** a notification on this Mac when a server or site is bad two checks in a row, gets worse, or recovers.

**The DevOps agent** (Settings › Server room) looks into your servers on its own heartbeat, on an alert and on **Run
now**. It reaches a server only through `Meatproxy --ops <server> <action>`, a fixed set of read actions and safe
fixes. What it may do is set per server: *Leave alone*, *Diagnose and ask* (reads only, every fix is a question for
you), or *Safe fixes* (restart a known service, prune old images and logs). It writes a journal of every run, shown in
the Server room. While a run goes, its person squats inside the Server room at the rack of the server it works on. The details: [docs/contracts/engine-room.md](docs/contracts/engine-room.md).

## 5. Optional connections

- **GitHub:** Meatproxy uses your own `gh` login to see failed CI runs and merged pull requests. Nothing to set up if
  `gh` works in your terminal.
- **Sentry and Tracker:** a token in Settings › Sources lets a factory wake on a new error or a changed story. Tokens
  are kept in the Keychain of this Mac.
- **Status pages:** the public status pages in Settings › Sources (Claude, OpenAI and GitHub by default; add or
  remove your own). They show in the Server room and on the status layer (⌘L).

## 6. The terminal

⌘J opens a terminal at the bottom of the window. Each tab runs one command:

- **Take over** a chat: `claude --resume <id>` (or `codex resume <id>`) where it started. A CEO run that is going
  stops first, and its factory waits until you close the tab. A chat that runs in the Claude app gets **Open in
  Claude** instead.
- **Terminal** on a server: `ssh` with your own keys.
- **Log** on a CEO or DevOps run: its log, live.

## 7. On a second Mac

Clone and run `scripts/make-app.sh` there too. Settings, factories, servers and costs are kept per Mac in
`~/Library/Application Support/Meatproxy/`, so nothing starts by itself on a new Mac: a factory wakes only after you
switch it on there.

## 8. Linux and Windows

The campus is a Mac app. On Linux and Windows there is no window yet, but the collector runs there, and so does
Meatproxy's command line: the same sessions, floors and Needs you list, as text.

```bash
git clone https://github.com/marcel-tuinstra/meatproxy.git
cd meatproxy
swift run meatproxy-core --dump      # every tower, floor and chat, and what waits for you
swift run meatproxy-core --watch     # the same, again whenever it changes
swift run meatproxy-core --costs     # each floor's sessions at API prices
```

You need Swift 6 ([swift.org/install](https://www.swift.org/install/)). `--dump --fixture` shows the made-up campus.

- **Where it reads:** `~/.claude/projects` and `~/.codex/sessions`, as on a Mac. On Windows `~` is your own folder
  (`C:\Users\you`), and a project is found by the same rules: the folder below `~\Projects`, or the git root.
- **Claude Code or Codex in WSL** keep their sessions inside WSL, not in Windows. Run `meatproxy-core` there, the
  Linux way.
- **Settings** are in the system's own place for them (`~/.local/share/Meatproxy` on Linux).
- **Tokens** for Sentry and Tracker come from `MEATPROXY_SENTRY_TOKEN` and `MEATPROXY_TRACKER_TOKEN`: there is no
  Keychain, so Meatproxy saves none.
- **A site's certificate:** an invalid one still fails the check, but the days until it expires only show on a Mac.
- **Factories and the Server room** (`--heartbeat`, `--ops`) are the same code as on a Mac, and their tests pass on
  Linux and Windows with stand-in programs. A real CEO run or server check has only ever been done on a Mac.
- **On Windows** Claude Code and Codex have to be the programs themselves (`claude.exe`, `codex.exe`): Meatproxy
  starts programs directly, so a `.cmd` wrapper from npm is not found.

## Privacy

Meatproxy reads local files only: your sessions, your git repositories, and `gh` with this Mac's login. It contacts
only the public status pages, and Sentry or Tracker when you add a token. What it reads from a session are short
labels (titles, the kind of action, file names, the program of a command), never file contents, output or full
command lines. There is no server, no account and no analytics. Settings › Privacy has the full list.

## When something looks off

- **The app is nowhere to be found:** it lives in `/Applications` after `scripts/make-app.sh`. A build from an older
  checkout only made `build/Meatproxy.app`.
- **A floor disappeared:** its last session is more than 8 hours old. Pin it to keep it.
- **A tower looks abandoned:** no chat with that provider in the last 8 hours.
- **A factory does not start:** the CEO card says why (no starter files, paused, a guardrail, a plan limit). Its logs
  are in `~/Library/Application Support/Meatproxy/heartbeats`.
