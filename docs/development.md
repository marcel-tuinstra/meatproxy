# Working on Meatproxy

Notes for changing the code. Using the app: [SETUP.md](../SETUP.md). Every design decision has an id (D1, D2, …) on
the maker's design board; the code refers to them in its comments.

## Run and test

It is a Swift package: no Xcode project needed.

```bash
swift run Meatproxy              # your own sessions, live
swift run Meatproxy --fixture    # made-up demo data: for demos and every screenshot you share
swift run Meatproxy --dump       # what the collector sees, as text
swift run Meatproxy --costs      # each floor's sessions at API prices
swift run Meatproxy --ops list   # the DevOps agent's ops tool: servers and actions
swift run meatproxy-core --dump  # the same modes without the app: also on Linux and Windows
swift test                       # FactoryCore, FactoryCollector and FactoryScenes
scripts/make-app.sh              # the app bundle, installed in /Applications
```

GitHub Actions runs `swift build` and `swift test` for every pull request, in three jobs: **swift test** on macOS
(everything), **Linux** and **Windows** (what builds there, below).

## macOS, Linux and Windows

The campus and the app are SpriteKit, SwiftUI and AppKit, which only a Mac has. The model, the collector and the
command line build and are tested on all three:

| | macOS | Linux | Windows |
| --- | --- | --- | --- |
| `FactoryCore`, `FactoryCollector` and their tests | yes | yes | yes |
| `meatproxy-core` (`--dump`, `--watch`, `--costs`, `--ops`, `--heartbeat`) | yes | yes | yes |
| `FactoryScenes`, `Meatproxy` (the app) | yes | no | no |

`Package.swift` leaves the Mac's targets out where the build does not run on a Mac. To keep the shared code shared:

- **Nothing of a Mac in `FactoryCore` or `FactoryCollector` without a way round it.** What only one system has goes
  behind `#if canImport(Security)` or `#if os(…)`, next to what the others do instead. `Platform.swift` has the two
  that come back everywhere: `Tools` (where claude, codex, gh and ssh are, by the usual places and the PATH) and
  `Processes` (starting a process that can be stopped, and whether the process in a lock file still lives).
- **A folder is text in its own system's spelling.** A session file from Windows says `C:\Users\you\Projects\shop`.
  `PathText` reads that the same on every platform, and `ProjectResolver` gives it the same floor as a Mac would.
- **Tests start no `/bin/sh` on their own.** `Stub` (in `PlatformTests.swift`) has a program that sleeps and one that
  exits, for every platform; a test that really needs a shell says so with `.enabled(if: Stub.hasShell)`.
- **`Package.resolved` is the Mac app's.** SwiftTerm is named on every platform, so a build on Linux leaves that
  file alone (CI checks it). On Windows SwiftTerm needs one package fewer and SwiftPM rewrites the file: leave that
  change out of a commit (`git restore Package.resolved`).
- **On Windows a write and a starting process never overlap.** Foundation there lets a process that starts take
  along a file that is being written, and the write fails. `Files.write` (and `write(wholeTo:)`), `Files.create`
  and `Processes.start` take turns; use them instead of `write(to:options: .atomic)`, `createFile` and `run()`.

Without a Mac, or to try Linux on one, Docker runs the tests (read-only, so nothing lands in your checkout):

```bash
docker run --rm -v "$PWD":/src:ro -w /src swift:6.4-noble swift test --scratch-path /tmp/build
```

## Window shots

A PNG of the whole window, HUD included, without touching your screen:

```bash
SF_WINDOW_SHOT=out.png SF_WINDOW_SHOT_AFTER=12 SF_WINDOW_SHOT_ACTION="floor:claude:/demo/shopfront" swift run Meatproxy --fixture
```

The path goes through an environment variable because AppKit opens a path on the command line as a document.
`SF_WINDOW_SHOT_ACTION` runs steps, comma-separated and two seconds apart, starting 3.5 seconds after launch. Each
step is one of:

- **Moving around:** `next`, `up`, `building:<claude|chatgpt>`, `engine`, `floor:<project id>`, `session:<id>`,
  `decision:<project id>|<D-id>`, `workstream:<project id>|<W-id>`, `zoom:<factor>`.
- **Mouse and keys:** `hover:x,y`, `click:x,y` and `uiclick:x,y` (the last through the window, so HUD buttons get it).
- **The campus:** `hour:<h>`, `apart:<tower>`, `mark:<k>`, `life:demo`, `leave:<project id>` (a floor leaves its
  tower), `devops:<server>` (the DevOps agent at work at that server's rack; `devops:off` ends it).
- **Settings that change every screen:** `text:larger` (Text size Larger), `keys:off` (single-key shortcuts off).
- **Waiting:** `wait:<seconds>`.

The right-click menu is the Mac's own menu, in a window of its own: `context:x,y` opens it, but a window shot does not
capture it.

Two variables change what a shot captures:

- `SF_WINDOW_SHOT_BURST="4@0.25"` takes four shots a quarter second apart.
- `SF_WINDOW_SHOT_RECORD="sec@fps[@scale[@speed]]"` records the world as frames (`f-NNNN.png` and `f-times.txt`).
  Speed below 1 slows the world down, so every frame lands on an even beat. `SF_WINDOW_SHOT_HUD="0.4"` puts the HUD
  on every frame too, captured again every 0.4 seconds of the world's time. That is how the trailer and the README loops
  were made.

Screenshots and recordings for anything public use `--fixture`: real sessions, projects, servers and alerts never go
in this repository.

## Layout

| Target | What |
| --- | --- |
| `FactoryCore` | The model (provider → project → session → sub-agent), states, roles, rooms, factories and their contract, the demo data |
| `FactoryCollector` | Reads `~/.claude/projects` and `~/.codex/sessions` read-only; projects, factories, the heartbeat, the Server room and its ops tool; the modes without a window (`Headless`) |
| `meatproxy-core` | The command line on every platform: `Headless`, and nothing else |
| `FactoryScenes` | The worlds in SpriteKit: the art engine, the campus, the floors |
| `Meatproxy` | The app: the HUD (Needs you, the inspector, settings, the terminal) |

## The art

The art is generated, not drawn: `Sources/FactoryScenes/Art/src/art/` holds the blocky people (`blocky-cast.js`), the
props and the ground, and the campus (`blocky-campus.js`). The app runs these scripts in a hidden WebKit view
(`ArtEngine`, through `Art/engine.html`). `Art/src/app/engine.js` draws them layer by layer and returns images:

- the ground as one image;
- every object as its own sprite with a depth key, packed on atlas pages;
- every person as a set of frames: walking, standing, typing, sitting, reading and more, from four sides.

SpriteKit sorts them, walks people from room to room, animates and zooms. Objects the app moves by itself (ducks,
birds, the balloon) carry an id in the art. People who live on the campus come as `npcs` and get a loop of poses.
Change the art, rebuild, and the app follows; `Art/engine.html` also works in a browser (`sf.campus(…)`,
`sf.figure(…)` in the console).

## Contracts

What Meatproxy and an agent expect from each other is a versioned contract, never a loose agreement:

- [docs/contracts/factory.md](contracts/factory.md): `meatproxy-factory`, version 6.
- [docs/contracts/engine-room.md](contracts/engine-room.md): `meatproxy-engine-room`, version 2.

A change to either is a new version with its own row, before the app or a factory relies on it.

## Brand

Tuinstra Meatproxy is a parody of the maker's own brand: a check mark of 16 × 16 pixels, one yellow (#FFD83D) for
the primary action and for what waits for you, neutral darks for everything else, and buttons that press down on
their ledge. The app icon is `Sources/Meatproxy/Brand/AppIcon.png`.
