# Inside the spangap build-env container

You are running as **`ubuntu` inside the spangap build-env container** (you most
likely got here via `spangap docker claude` on the host). This file tells you what
that means: what's mounted, what `spangap` does *from in here*, what you can and
can't do without the host, and how to help with the real job — **writing and
maintaining straddles**.

The firmware/browser code map is [`../spangap-core/CLAUDE.md`](../spangap-core/CLAUDE.md);
the design *why* + full gotcha list is [`INTERNALS.md`](INTERNALS.md). This file is
the container-side map.

## Where you are

You're `ubuntu`, cwd **`/workspace`**, `HOME=/home/ubuntu`. The container is started
with `sleep infinity` and you reach it by `docker exec`; it always carries at least two
host bind mounts — **`/workspace`** (the spangap workspace dir) and **`/home/ubuntu`**
(persistent home) — plus optionally **`/repos`** (only when this workspace was init'd
with `--repo-path`; see below). On macOS Docker Desktop these mounts are `fakeowner`
type, which drives a couple of gotchas at the end of this file.

Don't assume the rest of your situation — **discover it.** `spangap doctor` reports the
resolved project + toolchain; `ls /workspace` and `ls /repos 2>/dev/null` show what's
mounted; the workspace dotfiles tell you the mode:

- `/workspace/spangap.workspace.yaml` — the workspace marker (always present).
- `/workspace/.spangap-repo_path` — **present ⟺ `--repo-path` mode** (its contents are
  the host checkout path that's bind-mounted at `/repos`). Absent ⟹ clone mode.
- `/workspace/.spangap-project` — the default buildable straddle, if one was set at
  `init` (a bare `spangap build` from `/workspace` then targets it, no `cd` needed).
  **This is your main orientation pointer.** The user is most likely working on this
  specific project, so resolve it to its straddle dir (`<root>/<that-repo>/`) and **read
  its `README.md` first** (then `INTERNALS.md` / any `docs/`). The buildable straddle is
  where the project's identity *and its target hardware* live — the board HAL, pin map,
  partition layout, and OTA key are all owned there — so that README tells you what's
  being built and **which board it compiles for**. If `.spangap-project` is absent, the
  user targets a straddle by `cd`-ing into its dir instead.
- `.spangap-port-<os>-<arch>` (sticky serial port) and `.spangap-venv-<os>-<arch>/`
  also live here. **That venv is the *host's* flash/monitor tooling**
  (esptool/esp-idf-monitor), built for the host OS/arch — **not runnable in this
  container**. Ignore it.

### What a straddle is

A **straddle** is the platform's unit of distributable functionality: one git repo
with a `straddle.yaml` manifest at its root and, optionally, a firmware half
(`esp-idf/`, an ESP-IDF managed component), a browser half (`browser/`, TS/Vue/Quasar),
and an on-device-UI slice (`esp-idf/lcd/`). It "straddles" the two sides of the
platform — device and browser — as one versioned, dependency-declaring package. They
are **polyrepo** (each its own repo); a build *assembles* a chosen subset into one flat
tree (see ["What `spangap build` does"](#what-spangap-build-does-under-the-hood)).

### Where the straddles live

`spangap-inside` scans **two** container-native roots, in this order, and a straddle in
either is equally usable:

- **`/workspace/<repo>`** — git clones. This is the **default** mode (no `--repo-path`),
  and what most sessions see: `init` clones the build-system skeleton (`spangap`), the
  project, and every transitive dep into the workspace as flat sibling dirs, and they
  stay pinned there. **Look here first.**
- **`/repos/<repo>`** — a **flat `--repo-path` checkout** bind-mounted whole, *only* when
  the workspace was init'd with `--repo-path <dir>`. When this mode is in play, the
  straddles are under `/repos` and `/workspace` holds just workspace state (marker,
  dotfiles, host venv); `/repos` isn't mounted at all otherwise.

Quick check: `cat /workspace/.spangap-repo_path 2>/dev/null` — a path means look in
`/repos`, nothing means look in `/workspace`. (The two roots are disjoint by
construction: repo_path mode never clones into `/workspace`.)

Both roots are **host bind mounts**, so anything you write under a straddle's `build/`
is read directly by the host flasher, and the container path (`/workspace/<repo>` or
`/repos/<repo>`) is what gets baked into `build/CMakeCache.txt`'s `CMAKE_HOME_DIRECTORY`
— stable and host-independent. **Never bake a host-absolute path into the build.**

## `spangap` in here = the in-container CLI

`/usr/local/bin/spangap` is **not** the user-facing entry script — it's a thin
wrapper that sources `$IDF_PATH/export.sh` (so `idf.py`/the toolchain land on PATH)
and execs **`spangap-inside`** (`/usr/local/lib/spangap/cli.py`). So from this
container these verbs work directly, with the IDF env already set up:

| works in here | what it does |
|---|---|
| `spangap build [-v] [-e/-i <straddle>] [--no-lcd/--no-web] [--flash-size MB] [idf args…]` | resolve deps → stage → lint → `idf.py build` (+ browser build) |
| `spangap validate` | parse + jsonschema-check the manifest and dep graph (fast, read-only) |
| `spangap list-requires` / `list-deps` | full transitive set / missing siblings (read-only diagnostics) |
| `spangap clean` / `reallyclean` | `idf.py fullclean` / strip **every** straddle in the active root back to source (gitignored artifacts only) |
| `spangap doctor` | env report: python, IDF_PATH, node/npm/idf.py versions, resolved project |
| `spangap cli [-h host] <cmd>` | talk to a running device over the network (TCP CLI) |
| `spangap flash` | **signal only** — touches `build/flashme` and waits ≤5s for a host monitor to consume it (see below) |

**`spangap flash` / `spangap cli` from in here don't touch hardware directly** — the
container has no USB. `flash` only signals a host monitor; `cli` reaches the device
over the network. The full device loop is its own section below
([Working with a real device](#working-with-a-real-device--the-you--user--board-loop)).

**Host-only verbs you can't run from this container:** `monitor`, `probe`, real
`flash`, `init`, `reset`, `get-deps` (the cloning side), and `docker <cmd>` — those
live in **`spangap-outside`** on the host and need the serial port / docker / the
container lifecycle. There is **no `docker` and no `esptool.py`** in here by design
(no docker-in-docker; esptool is host-side in the per-host venv).

### Toolchain directly

- `idf.py` is **only on PATH after** `. $IDF_PATH/export.sh` (the `spangap` wrapper
  does this for you; a raw shell you open does not). Prefer `spangap build` /
  `spangap build <idf args>` over calling `idf.py` yourself so staging + the
  `${SPANGAP_REQUIRES}` wiring actually happen first.
- `node` / `npm` are on PATH (Node 20). The browser build runs in-container during the
  firmware build (`npm install` only if `node_modules` is missing, then `npx quasar build`).
- `python3` (system) has `pyyaml` + `jsonschema`; the IDF venv has Pillow/cairosvg/pypng/lz4
  for the LCD icon rasterizer. `git` is present.

## Working with a real device — the you ↔ user ↔ board loop

**This container has no serial ports and no `esptool`** — it cannot talk to hardware
directly. Everything device-side flows through a **`spangap monitor` the user runs on
the host**, plus the device's network CLI. Set this up once and you can iterate tightly
without the user touching anything per cycle.

**1. Let you flash.** Ask the user to run, **on the host, from the project directory**
(or the workspace root if `.spangap-project` is set), and leave it running:

```sh
spangap monitor <port>      # <port> is sticky after the first time
```

It's a passive serial monitor (`--no-reset`, so it won't reboot the board while idle)
that also **watches `<fw>/build/flashme`**. Your flash loop then is:

1. `spangap build`  *(in here)*
2. `spangap flash`  *(in here — just touches `build/flashme`)*
3. the host monitor sees `flashme`, flashes the board over USB, and re-attaches with a
   reset for a clean boot.

The monitor **must** be started from the project dir / workspace root — run outside a
straddle it warns *"cannot be signalled to flash"* and the handshake won't work. If
your `spangap flash` reports *"nobody seems to be running `spangap monitor`"* after 5s,
it isn't up (or isn't in the project dir) — ask the user to (re)start it there.

**2. See what the board is doing.** The monitor writes a live, ANSI-stripped copy of
the serial output to **`<project>/esp-idf/build/flasher.log`** (the firmware half lives
in the `esp-idf/` subdir — that's the `firmware:` value in every straddle.yaml) — it's
on the bind mount, so you can `tail -f` / read it from in here. **This is your only
window into the device — use it.**
In particular it's where you check:

- **whether networking came up and the device's IP address** — watch for the net
  task's "upstream up" / DHCP / IP lines (you'll need that IP for step 3),
- boot progress and log output (`info/warn/err`, tagged `[taskname]`),
- panic backtraces (decoded to `file:line` when the app ELF is present).

It's truncated on each flash, so it reflects the **current** boot.

**3. Drive the device over the network.** By default the device CLI is serial-only. To
let you reach it from in here, have the user type — **in the monitor window** (that
window is a live serial CLI to the device) — :

```
set s.net.cli_port=2323
```

That opens the device's TCP CLI on port **2323** (the `s.` prefix persists it to flash).
From then on, from inside this container:

```sh
spangap cli -h <device-ip> get s.net      # IP from flasher.log; -h is sticky, omit it afterwards
spangap cli set s.some.key value          # subsequent calls reuse the sticky host
```

`spangap cli` defaults to port 2323 to match. **Device CLI commands are silent on
success** (`set` / `unset` / `save` print nothing when they work) — no output means it
worked, not that it hung.

**Iteration tips.**

- **Sticky state:** the serial port (`.spangap-port-<os>-<arch>`) and CLI host
  (`.spangap-host`) are remembered — set each once, omit thereafter.
- **One terminal, both jobs:** the single host `spangap monitor` gives the *user* the
  live console *and* gives *you* the flash signal + the `flasher.log` to read. Once it's
  running, a normal cycle needs no user action: you build, you `spangap flash`, you read
  `flasher.log`.
- **Config you change sticks:** `s.*` keys persist to flash and sync to the browser;
  `secrets.*` persist but never leave the device; no-prefix keys are ephemeral (gone on
  reboot). So `spangap cli set s.…` survives a reboot; setting a bare key doesn't.
  (Details: `spangap-core/docs/storage.md`.)
- **Stack decode** needs the build's ELF, which the monitor finds in `esp-idf/build/` —
  so flash a build you actually built here and panics in `flasher.log` resolve to source.

## The straddle tree (`/workspace` or `/repos`)

Whichever root applies (above), it's a **flat** directory of straddle dirs. A fully
populated checkout of the core platform plus a downstream project looks like:

```
<root>/
├── spangap/        ← THIS repo: the entry script + build-system/ (you're reading its CLAUDE.md)
├── spangap-core/   platform runtime, prefix "" (storageGet, cliRegister, info…)  — has its own CLAUDE.md + docs/
├── spangap-net/    IP+TLS+NTP+mDNS (net)   spangap-web/  HTTPS+auth+WebRTC+browser shell (web, a UI activator)
├── spangap-lcd/    on-device LVGL launcher (lcd, the other UI activator)
├── ota/ wg/ upnp/ duckdns/ acme/ maps/ sshd/   central + optional straddles
└── <project>*/     a downstream project (e.g. the reticulous mesh straddles) built ON spangap
```

(Straddle definition is above. Here, **not** a monorepo — the build assembles a
per-buildable subset into one flat tree.) The flat layout is **mandatory**: on macOS
Docker Desktop a symlink resolves through to its host target, so the browser
`file:../../<sibling>/browser` deps only resolve when straddle roots are flat siblings
(INTERNALS → "Flat repo_path"). Don't add an org/ layer.

`straddle.yaml` keys (contract: `build-system/schemas/straddle.schema.json` — the
**authoritative** list; the schema is local, read it before hand-writing a manifest):
`name` (`<org>/<repo>`), `prefix` (symbol/import prefix; empty reserved for
spangap-core), `version` (`X.Y.Z`); `requires` (hard — missing = error, can't
`--exclude`), `optional_requires` (soft, **default-on**, pruned silently when absent —
call sites **must** gate on `CONFIG_*`); `firmware:` / `browser:` (paths to the two
halves, e.g. `esp-idf` / `browser`); **`init:`** (bring-up function name — see the
auto-init note below); `buildable:` (an **object**, not a bare flag: presence marks a
flashable image, and it carries `firmware` / `browser` / `lcd` entry paths).

### The straddle namespace map (prefix ≠ repo name)

`prefix` is the symbol prefix *and* the browser import name, and it is **frequently not
the repo name** — so check this before picking one (and before writing a `CONFIG_*`
gate, which keys off the **repo name**, not the prefix):

| repo | prefix | repo | prefix |
|---|---|---|---|
| `spangap-core` | `""` (reads as language primitives: `storageGet`, `info`…) | `rns` | `rns` |
| `spangap-net` | `net` | `tr-tcp` | `rns_tcp` |
| `spangap-web` | `web` | `tr-auto` | `rns_auto` |
| `spangap-lcd` | `lcd` | `tr-espnow` | `rns_espnow` |
| `acme` `duckdns` `upnp` `wg` `ota` | (= repo) | `tr-lora` | `rns_lora` |
| `sshd` | `sshd` | `lxmf` | `lxmf` |
| `maps` | `maps` | `nomad` | `nomad` |
| | | `hw-tdeck` | `tdeck` |

This table can go stale — `spangap-inside` reads the real values; `ls /repos` +
`grep -h '^prefix:' /repos/*/straddle.yaml` is the source of truth. Note `sshd` and
`maps` exist as straddles but are **absent from the org-README straddle tables and from
the `CONFIG_SPANGAP_*` alias list** below — don't assume the documented set is complete;
enumerate `/repos`.

## What `spangap build` does under the hood

1. resolve `requires ∪ optional_requires ∪ --include`, transitively, minus `--exclude`/`--no-X`.
2. stage each kept dep into `staging/components/<repo>/`: symlinks to source + a generated
   `spangap_requires.cmake` (`set(SPANGAP_REQUIRES …)`), plus a synthetic `_spangap_present`
   component whose `Kconfig.projbuild` declares `CONFIG_STRADDLE_<UPPER_REPO>` (default y)
   per staged straddle, with aliases `CONFIG_SPANGAP_LCD/WEB/OTA/WG/UPNP/DUCKDNS/ACME`.
3. write `staging/sdkconfig.spangap-overrides` (e.g. `--flash-size`); partition table derives
   from flash size + app-percent + **whether `staging/components/ota/` exists** (not a Kconfig knob).
4. **lint**: reject any `idf_component_register(REQUIRES …)` that hand-writes a known straddle
   repo name — cross-straddle deps MUST flow through `${SPANGAP_REQUIRES}`.
5. `idf.py build` (which drives the browser build).

Consumer CMake idiom: `include(${CMAKE_CURRENT_LIST_DIR}/spangap_requires.cmake)` then
`REQUIRES ${SPANGAP_REQUIRES} …`. The buildable's `main/CMakeLists.txt` reads
`${CMAKE_CURRENT_LIST_DIR}/../staging/main_requires.cmake` — **`CMAKE_CURRENT_LIST_DIR`,
not `CMAKE_SOURCE_DIR`** (the latter breaks in IDF's requirements pre-pass).

**Auto-init (don't hand-wire `xInit()` in `app_main`).** The build also collects every
staged straddle's `init:` hook, topologically orders them by `requires`, and generates a
**`spangapInitStraddles()`** dispatcher into `staging/` (alongside `main_requires.cmake`).
The buildable calls that **one** function from `app_main()`; you do **not** list each
straddle's init by hand. Two consequences for a straddle author: (1) declare your bring-up
function in `init:` rather than asking the app to call it, and (2) that function uses
**plain C++ linkage** — the generator emits each forward decl as `void xInit(void);` with
default (C++) linkage, so your `init:` symbol must be a C++ `void xInit(void)` whose header
does **not** wrap it in `extern "C"`, or the dispatcher fails to link (an init defined in a
`.c` file needs an `extern "C"` wrapper to match). **Caveat:** the schema's own `init.call`
*description* still says the symbol must be `extern "C"` — that prose is stale; the emitted
C++-linkage decl is what actually links. (This whole mechanism supersedes the long manual
`app_main()` init sequences still shown in some sibling READMEs — see the stale-doc caveats
below.)

## Editing the build system from inside this container

**The `spangap` you run is baked into the image.** The Dockerfile `COPY`s
`build-system/spangap-inside` → `/usr/local/lib/spangap/cli.py`. So editing the source
under `<root>/spangap/build-system/spangap-inside` changes the **source**, not the
running CLI — your edit won't take effect via `spangap …` until the image is rebuilt
(which happens host-side: `spangap-outside` notices the `build-system/` content hash
diverged from the image's `org.spangap.buildsys-hash` LABEL and rebuilds on the next
host command).

To **test an edit to the in-container CLI without a rebuild**, run the source copy
directly (use the spangap repo's actual path — `/workspace/spangap` in clone mode,
`/repos/spangap` under `--repo-path`):

```sh
. "$IDF_PATH/export.sh"                              # only needed for build; not for validate/list-*
python3 .../spangap/build-system/spangap-inside validate        # or list-requires, build, …
```

`spangap-outside` (POSIX `/bin/sh`) and the Dockerfile are **host-build-time**
artifacts — editing them here is fine, but they only matter on the host / at the next
image build, never to the currently-running container.

## Helping write or maintain a straddle

1. **Manifest** — `straddle.yaml` with `name`/`prefix`/`version`; pick `prefix` with
   care (symbol prefix *and* browser import name — check it's free in the namespace map
   above). If the straddle has bring-up code, declare it via **`init:`** (C++-linkage
   function, no `extern "C"`) so the generated `spangapInitStraddles()` calls it in
   dependency order — don't expect the app to hand-call it. Check with `spangap validate`.
2. **Deps** — hard → `requires`; integrate-when-present → `optional_requires`, and
   **gate every such call site** on `CONFIG_STRADDLE_<UPPER_REPO>` (or a
   `CONFIG_SPANGAP_*` alias) so a pruned dep still links. Ungated optional dep = the
   classic break.
3. **CMakeLists** — cross-straddle deps via `${SPANGAP_REQUIRES}` only; never
   hand-write a sibling's repo name in `REQUIRES` (the staging lint rejects it).
4. **Firmware half** (`esp-idf/`, an IDF managed component) — follow spangap-core
   conventions: `info()/warn()/err()/dbg()` not `ESP_LOGx`; `safeStrncpy`; ITS for all
   task-to-task comms; modern C++; **no PlatformIO**. Recipes (CLI cmd, ITS port,
   DataChannel, settings panel, cron, net callback) are in INTERNALS → "Common recipes".
5. **Browser half** (`browser/`, TS/Vue/Quasar) — register UI through `menuRegistry`
   and the `Setting*` components from `spangap-web`.
6. **On-device UI** — optional `esp-idf/lcd/` slice; `spangap-lcd` folds it in and
   calls `<prefix>LcdInit()`.
7. **Making it buildable** — add the `buildable:` block; then, per the package-lock
   policy (INTERNALS): **commit** `package-lock.json` in buildable straddles, **ignore**
   it in libraries (drop it from `.gitignore` when a straddle becomes buildable).

After any manifest/dep/CMake change, the fast in-container check is `spangap validate`
then `spangap list-requires`; a real `spangap build` confirms staging + linking.

## Container gotchas

- **No serial, no docker, no esptool in here** — flashing/monitoring is host-side; from
  here `spangap flash` only signals via `build/flashme`, and you read the device through
  the host monitor's `esp-idf/build/flasher.log` (see "Working with a real device").
- **On macOS Docker Desktop, `fakeowner` shows every file mode 0755**, which makes git
  report spurious `100644→100755` flips. Straddle checkouts set `core.fileMode false` —
  leave it; don't "fix" the mode noise or chmod to silence it.
- **The running `spangap` is the image copy**, not the source tree (see "Editing"
  above). Don't expect source edits to take effect through `spangap …` without a rebuild.
- **Under `--repo-path`, `/repos` is a pinned checkout** — nothing is ever cloned; a
  missing required straddle is an error ("add it to the checkout"), not a fetch. In clone
  mode, missing transitive deps are fetched host-side into `/workspace`.
- **`reallyclean` is workspace-wide** — it reaches across *every* straddle in the active
  root (including into a `--repo-path` checkout, since `/repos` *is* that checkout), but
  only removes gitignored, regenerable output.

## Stale-doc caveats (the sibling READMEs are mid-rewrite — don't trust these bits)

The straddle READMEs were recently rewritten and several carry `README-old.md` and
superseded per-straddle `CLAUDE.md` files. Four concrete traps when reading them:

- **The flat layout is real; the `s/` paths in docs are not.** Some READMEs (notably
  `hw-tdeck`) link siblings as `../../s/spangap/INTERNALS.md` or
  `[…](../../s/)`. There is **no `s/` directory** — `/repos` (or `/workspace`) is flat,
  as this file's tree shows. Resolve any `s/`-style link to `/repos/<repo>/…` directly.
- **README file-layout boxes are partly aspirational.** The org-profile README and
  `spangap-core` README describe the spangap repo as `cli/spangap`, `install/spangap`,
  `scripts/`, etc. The **actual** tree is `build-system/{spangap-inside, spangap-outside,
  Dockerfile, schemas/}` + the `spangap` shim — no `cli/`, `install/`, or `scripts/`.
  Trust this file and `ls` over those boxes.
- **Per-straddle `CLAUDE.md` files are superseded.** Their content moved into
  `INTERNALS.md` (per-straddle + the platform-wide `spangap/INTERNALS.md`) and
  `spangap-core/docs/`. The "Read next" pointer below to `../spangap-core/CLAUDE.md` may
  resolve to a stale file — prefer those `INTERNALS.md` / `docs/` as canonical.
- **The hand-written `app_main()` init sequences are obsolete.** READMEs that show
  `pmInit(); logInit(); fs_init(); …` enumerated by hand predate auto-init; today that
  is one `spangapInitStraddles()` call (see "Auto-init" above).

Platform realities not stated elsewhere in this file, but assumed everywhere: target is
**ESP32-S3 with octal PSRAM (mandatory)**, toolchain is **ESP-IDF 5.5.4** + Node 20.
The PSRAM/DRAM split is a live firmware hazard — a flash op disables the PSRAM cache, so
a task on a PSRAM stack that touches LittleFS **crashes**; route all I/O through the
`fs_*` API (the reason `fs.cpp`'s DRAM worker tasks exist). DMA/WiFi/lwIP need internal
DRAM.

## Read next

- [INTERNALS.md](INTERNALS.md) — staging/gating internals, the rejected alternatives,
  ITS/storage/recipes, full gotcha list.
- [../spangap-core/CLAUDE.md](../spangap-core/CLAUDE.md) + [../spangap-core/docs/](../spangap-core/docs/)
  — firmware/browser code map and subsystem deep-dives.
- [README.md](README.md) / [CONTRIBUTING.md](CONTRIBUTING.md) — host install story; DCO sign-off
  (`git commit -s`, enforced by `.github/workflows/dco.yml`).
</content>
