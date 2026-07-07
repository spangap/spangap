# Inside the spangap build-env container

This is a spangap workspace directory. It's where spangap projects get assembled and built. You may be seeing this from the host system or from inside the spangap build system docker container. If you are inside the container, you are running as user `spangap`. This file tells you what that means: what's mounted, what `spangap` does *from in here*, what you can and
can't do without the host, and how to help with the real job — **writing and
maintaining straddles**.

The firmware/browser code map is [`../spangap-core/README.md`](../spangap-core/README.md)
and its [`docs/`](../spangap-core/docs/); the design *why* + full gotcha list is
[`INTERNALS.md`](INTERNALS.md). This file is the container-side map.

## Where you are

You're `spangap`, cwd **`<workspace>`** and the container carries the
host bind mount **`/home/spangap`** (persistent home, with the workspace nested under it
at `/home/spangap/<basename>`). On macOS Docker Desktop these mounts are `fakeowner`
type, which drives a couple of gotchas at the end of this file.

Don't assume the rest of your situation — **discover it.** Running bare `spangap` reports the
resolved project + its deps + the toolchain/environment. Running 'spangap' and looking at the output should ALWAYS be the first order of business to get the lay of the land.

- `<workspace>/spangap.workspace.yaml` — the workspace marker (always present).
- `<workspace>/.spangap-build` — the **last build invocation**, target first:
  `<org/repo> [--with …] [--without …] [--flash-size N]`. Written by `spangap build`
  whenever a target is named explicitly or resolved from cwd, so a bare `spangap build`
  (and `flash`/`monitor`/`show`) from `<workspace>` repeats it with no `cd` needed.
  **This is your main orientation pointer.** Its target names the straddle the user is
  most likely working on, so resolve it to its straddle dir (`<root>/<that-repo>/`) and
  **read its `README.md` first** (then `INTERNALS.md` / any `docs/`). That buildable
  straddle is where the project's identity *and its target hardware* live — the board
  HAL, pin map, partition layout, and OTA key are all owned there — so its README tells
  you what's being built and **which board it compiles for**. The `--with` line often
  names that board straddle (e.g. `--with spangap/hw-tdeck`). If `.spangap-build` is
  absent (nothing built yet), the user names a target with `spangap build <org>/<repo>`
  (cloned + remembered on first build) or `cd`s into a straddle dir.
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

`spangap-inside` scans one container-native root:

- **`<workspace>/<repo>`** — git clones, laid out flat as sibling dirs. `init` clones
  just the build-system skeleton (`spangap`); the first `spangap build <org>/<repo>`
  then clones the project and every transitive dep into the workspace as flat sibling
  dirs, where they stay pinned. **Look here.**

The workspace is a **host bind mount**, so anything you write under a straddle's `build/`
is read directly by the host flasher, and the container path (`<workspace>/<repo>`) is
what gets baked into `build/CMakeCache.txt`'s `CMAKE_HOME_DIRECTORY` — stable and
host-independent. **Never bake a host-absolute path into the build.**

## `spangap` in here = the in-container CLI

`/usr/local/bin/spangap` is **not** the user-facing entry script — it's a thin
wrapper that sources `$IDF_PATH/export.sh` (so `idf.py`/the toolchain land on PATH)
and execs **`spangap-inside`** (`/usr/local/lib/spangap/cli.py`). So from this
container these verbs work directly, with the IDF env already set up:

| works in here | what it does |
|---|---|
| `spangap build [-v] [-w/--with <straddle>] [-x/--without <straddle>] [--no-lcd/--no-web/--no-net] [--flash-size MB] [idf args…]` | resolve deps → stage → lint → `idf.py build` (+ browser build) |
| `spangap menuconfig [--save]` | interactive Kconfig editor (`idf.py menuconfig`) over the staged project; `--save` writes the minimal `sdkconfig.defaults` (the "configure a board straddle, save as `hw-whatever`" step) |
| `spangap autoconfig` | leave manual-kconfig mode (drop `.spangap-manual-kconfig`) and reseed `sdkconfig` from `sdkconfig.defaults` on the next build |
| `spangap validate` | parse + jsonschema-check the manifest and dep graph (fast, read-only) |
| `spangap list-requires` / `list-deps` | full transitive set / missing siblings (read-only diagnostics) |
| `spangap clean` / `reallyclean` | `idf.py fullclean` / strip **every** straddle in the active root back to source (gitignored artifacts only) |
| `spangap show` | project straddle + deps in init order, the env report (python, IDF_PATH, node/npm/idf.py versions), and whether a host `spangap monitor` is ready to flash (bare `spangap` with no subcommand does the same; `show` stays as an explicit alias) |
| `spangap cli [-h host] [<cmd>]` | talk to a running device over the network (ssh, else TCP CLI) |
| `spangap flash` | **signal only** — touches `.spangap-flashme` (workspace root) and waits ≤5s for a host monitor to consume it (see below) |
| `spangap reset` | **signal only** — touches `.spangap-resetme` (workspace root) and waits ≤5s for a host monitor to consume it; the monitor restarts with a device reset (clean reboot + boot-log capture), no reflash |
| `spangap log [-f]` | print the device serial log (`.spangap-log`); streamed from the host monitor's relay (`host.docker.internal:2324`) because the bind mount is stale inside the container (a plain `cat`/`tail` — and even `O_DIRECT` — freeze; see below); `-f` follows like `tail -f` and survives flash/reset truncations |

**`spangap flash` / `spangap reset` / `spangap cli` from in here don't touch hardware
directly** — the
container has no USB. `flash`/`reset` only signal a host monitor; `cli` reaches the device
over the network. `spangap cli "<cmd>"` runs an **arbitrary** device CLI command and returns
its output (`spangap cli gps`, `spangap cli "set s.gps.interval=5"`) — combine it with
`spangap log` to verify firmware autonomously. Note that only the `spangap`-mediated verbs
route to the device: the **raw socket level is not reachable from the container** — `nc` to
the device's ssh (`:22`), web (`:80`/`:443`), or TCP CLI (`:2323`) is refused, because the
host bridge terminates on the host's own loopback with no container route. Raw-socket work
(the browser config-channel, an ssh `Ctrl-D`, physical checks) stays user-driven. The full
device loop is its own section below
([Working with a real device](#working-with-a-real-device--the-you--user--board-loop)).

**Host-only verbs you can't run from this container:** `monitor`, `probe`, real
`flash`, `init`, `reset-workspace`, `get-deps` (the cloning side), `push-all`
(create + push every straddle repo to GitHub — runs `gh`/`git` with the host's
credentials, never in the container), `make-builds` (build every entry in a
builds repo's `builds.yaml` and collect each `build/flasher.zip` to
`<name>.zip` in the builds-repo root), and `docker <cmd>` — those
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
(or the workspace root, once something has been built — `.spangap-build` then names the
target), and leave it running:

```sh
spangap monitor <port>      # <port> is sticky after the first time
```

It's a passive serial monitor (`--no-reset`, so it won't reboot the board while idle)
that also **watches `.spangap-flashme`** at the workspace root. Your flash loop then is:

1. `spangap build`  *(in here)*
2. `spangap flash`  *(in here — just touches `.spangap-flashme`)*
3. the host monitor sees `.spangap-flashme`, flashes the board over USB, and re-attaches
   with a reset for a clean boot.

The monitor only runs in/under a workspace, and is best started from the project dir /
workspace root — run outside a straddle it warns *"cannot be signalled to flash"* and the
handshake won't work. If
your `spangap flash` reports *"nobody seems to be running `spangap monitor`"* after 5s,
it isn't up (or isn't in the project dir) — ask the user to (re)start it there.

**2. See what the board is doing.** The monitor writes a live, ANSI-stripped copy of
the serial output to **`.spangap-log` at the workspace root** — it's on the bind mount
(`<workspace>/.spangap-log` in here). **This is your only window into the device — use it.**

⚠️ **Read it with `spangap log` (or `spangap log -f`), NOT `cat`/`tail -f`.** The file
itself is **unreadable from inside the container** on Docker Desktop: the host holds it open
and appends, but the bind mount is **virtiofs with `keep_cache`**, so the container's cached
inode freezes at the size the file had when the monitor truncated it (0). Every in-container
reader — `cat`/`tail`/`stat`/`wc` and even `O_DIRECT`, `statx(FORCE_SYNC)`, `fadvise`,
`readdir`, and a `remount` — serves that stale size and stops reading at it, so the log
looks empty even though the bytes are on disk (`stat` shows `Size: 0` but nonzero
`Blocks:`). It is **not a flush delay and does not catch up**, and there is no way to bust
the cache from inside the container.

So `spangap log` doesn't read the file from in here — it streams the log over the network
instead. `spangap monitor` runs a small **serial-log relay** on the host (a TCP server in
the same host-side bridge that forwards the device ports — see `start_bridge`/`serve_log` in
`spangap-outside`, bound to `:2324`, `$SPANGAP_LOG_PORT`, and passed through on every
`docker exec`). Unlike the device-port forwards (which need a configured device address),
the log relay **always runs** — so `spangap log` works from the moment the monitor is up,
before the device is even reachable. In-container `spangap log`
connects to it at `host.docker.internal:2324`, sends `ONCE` (dump) or `FOLLOW` (`-f`,
`tail -f` style, survives the flash/reset truncation with a `--- log reset ---` marker), and
prints what the host reads natively (always fresh). This works **the same from the host and
from inside the container** — both go through the relay. If the relay is unreachable
(`spangap monitor` not running, or a native-Linux host with no relay), `spangap log` falls
back to a direct read of the bind-mounted file: authoritative on native Linux (the mount is
coherent there), and on Docker Desktop it prints a "relay unreachable — is monitor running?"
note since that read will be stale. (Dentry ops like `.spangap-flashme` propagate fine; only
growing-content does not — so only the log needs the relay.)

In particular `spangap log` is where you check:

- **whether networking came up and the device's IP address** — watch for the net
  task's "upstream up" / DHCP / IP lines (you'll need that IP for step 3),
- boot progress and log output (`info/warn/err`, tagged `[taskname]`),
- panic backtraces (decoded to `file:line` when the app ELF is present).

It's truncated on each flash, so it reflects the **current** boot.

**3. Drive the device over the network.** `spangap cli [<cmd>]` reaches the device, and
the host `spangap monitor` **owns the bridge** that fronts it (the container can't route
to the device's LAN, so on Docker Desktop it dials `host.docker.internal` and the monitor
splices to the real device; native Linux reaches the LAN directly). The monitor opens the
bridge on start from the configured device address and closes it on exit, so the bridge
only lives while a monitor is running. One workspace-root file names the device:

- **`.spangap-tcp`** — a bare `<host-or-ip>`: the **device address**. One address, many
  ports — ssh on 22, the legacy TCP CLI on 2323, the device's TLS/wss on 443. The port
  belongs to the transport, not the address, so it's never stored. Defaults to the
  project's `<default_hostname>.local` (e.g. `reticulous.local`) until set.

**`spangap cli` is foolproof** — it makes a working connection out of nothing, in order:
generate `~/.ssh/id_ed25519` if missing → ssh in (port 22) → fall back to the legacy TCP
CLI (2323) if that answers → if ssh is up but the key is refused, print a `sshd add
<pubkey>` line to paste **in the monitor window** (the live serial CLI) to authorize it →
if nothing answers, report whether the device pings and ask for its IP/host, then retry.
`sshd` ships enabled and admits no one without an authorized key; if it isn't in the build,
add it with `spangap build --with spangap/sshd`. `-h <host>` (re)writes `.spangap-tcp`.

```sh
spangap cli get s.net                     # over ssh; one-shot exec, prints and exits
spangap cli set s.some.key value          # subsequent calls reuse .spangap-tcp
spangap cli                               # no args → interactive shell
spangap cli -h 192.168.1.50               # point at a specific device, then connect
```

**TCP CLI alternative:** have the user type `set s.net.cli_port=2323` in the monitor window
(opens the device's TCP CLI; `s.` persists it to flash). When ssh isn't available, `spangap
cli` automatically uses that socket on the same `.spangap-tcp` address.

**`spangap dev`** runs the project's Quasar web SPA (`web-interface/`) hot from Vite,
reachable from outside the container: it starts the dev server (published to an ephemeral
host port, so concurrent workspaces never collide) and opens it in the OS browser at the
URL it prints, pointed at the active device address over
wss (`?host=<addr>&port=443`). It streams the dev console until you quit it. `-h <host>`
sets the device address first, same as `spangap cli`.

**Device CLI commands are silent on success** (`set` / `unset` / `save` print nothing when
they work) — no output means it worked, not that it hung.

**Iteration tips.**

- **Sticky state:** the serial port (`.spangap-port-<os>-<arch>`) and the device address
  (`.spangap-tcp`) are remembered — set each once, omit thereafter.
- **One terminal, both jobs:** the single host `spangap monitor` gives the *user* the
  live console *and* gives *you* the flash signal + the `.spangap-log` to read. Once it's
  running, a normal cycle needs no user action: you build, you `spangap flash`, you read
  `.spangap-log`.
- **Config you change sticks:** `s.*` keys persist to flash and sync to the browser;
  `secrets.*` persist but never leave the device; no-prefix keys are ephemeral (gone on
  reboot). So `spangap cli set s.…` survives a reboot; setting a bare key doesn't.
  (Details: `spangap-core/docs/storage.md`.)
- **Stack decode** needs the build's ELF, which the monitor finds in `esp-idf/build/` —
  so flash a build you actually built here and panics in `.spangap-log` resolve to source.

## The straddle tree (`<workspace>`)

The workspace root is a **flat** directory of straddle dirs. A fully
populated checkout of the core platform plus a downstream project looks like:

```
<root>/
├── spangap/        ← THIS repo: the entry script + build-system/ (you're reading its README.md)
├── spangap-core/   platform runtime, prefix "" (storageGet, cliRegister, info…)  — has its own README.md + docs/
├── spangap-net/    IP+TLS+NTP+mDNS (net)   spangap-web/  HTTPS+auth+WebRTC+browser shell (web, a UI activator)
├── spangap-lcd/    on-device LVGL launcher (lcd, the other UI activator)
├── ota/ wg/ upnp/ duckdns/ acme/ maps/ sshd/   central + optional straddles
└── <project>*/     a downstream project (e.g. the reticulous mesh straddles) built ON spangap
```

(Straddle definition is above. Here, **not** a monorepo — the build assembles a
per-buildable subset into one flat tree.) The flat layout is **mandatory**: on macOS
Docker Desktop a symlink resolves through to its host target, so the browser
`file:../../<sibling>/browser` deps only resolve when straddle roots are flat siblings
(INTERNALS → "Flat workspace layout"). Don't add an org/ layer.

`straddle.yaml` keys (contract: `build-system/schemas/straddle.schema.json` — the
**authoritative** list; the schema is local, read it before hand-writing a manifest):
`name` (`<org>/<repo>`), `prefix` (symbol/import prefix; empty reserved for
spangap-core), `version` (`X.Y.Z`); `requires` (hard — missing = error;
dropping one with `--without` cascades the drop to whatever hard-requires it, and is
refused only when it would take out spangap-core or a buildable hard-require),
`additional_installs` (soft, **default-on**, pruned silently when absent —
call sites **must** gate on `CONFIG_*`); `firmware:` / `browser:` (paths to the two
halves, e.g. `esp-idf` / `browser`); **`services:`** (boot-registered `Service` classes)
and the legacy **`init:`** / **`start:`** bring-up hooks — see the boot-registration note
below; `buildable:` (an **object**, not a bare flag: presence marks a
flashable image, and it carries `firmware` / `browser` / `lcd` entry paths);
**`settings:`** (a declarative settings-pane block lowered to LCD + web + storage
defaults at build time — see ["Declarative settings"](#declarative-settings-the-settings-block)).

### The straddle namespace map (prefix ≠ repo name)

`prefix` is the symbol prefix *and* the browser import name, and it is **frequently not
the repo name** — so check this before picking one (and before writing a `CONFIG_*`
gate, which keys off the **repo name**, not the prefix):

| repo | prefix | repo | prefix |
|---|---|---|---|
| `spangap-core` | `""` (reads as language primitives: `storageGet`, `info`…) | `rns` | `rns` |
| `spangap-net` | `net` | `iface-tcp` | `rns_tcp` |
| `spangap-web` | `web` | `iface-auto` | `rns_auto` |
| `spangap-lcd` | `lcd` | `iface-espnow` | `rns_espnow` |
| `acme` `duckdns` `upnp` `wg` `ota` | (= repo) | `iface-lora` | `rns_lora` |
| `sshd` | `sshd` | `lxmf` | `lxmf` |
| `maps` | `maps` | `nomad` | `nomad` |
| | | `hw-tdeck` | `tdeck` |

This table can go stale — `spangap-inside` reads the real values; `ls <workspace>` +
`grep -h '^prefix:' <workspace>/*/straddle.yaml` is the source of truth. Note `sshd` and
`maps` exist as straddles but are **absent from the org-README straddle tables and from
the `CONFIG_SPANGAP_*` alias list** below — don't assume the documented set is complete;
enumerate the workspace.

## What `spangap build` does under the hood

1. resolve `spangap-core (implicit) ∪ requires ∪ additional_installs ∪ --with`, transitively,
   minus `--without`/`--no-X` and the reverse-dependency cascade they trigger.
2. stage each kept dep into `staging/components/<repo>/`: symlinks to source + a generated
   `spangap_requires.cmake` (`set(SPANGAP_REQUIRES …)`), plus a synthetic `_spangap_present`
   component whose `Kconfig.projbuild` declares `CONFIG_STRADDLE_<UPPER_REPO>` (default y)
   per staged straddle, with aliases `CONFIG_SPANGAP_LCD/WEB/OTA/WG/UPNP/DUCKDNS/ACME`.
3. write `staging/sdkconfig.spangap-overrides` (e.g. `--flash-size`); partition table derives
   from flash size + app-percent + **whether `staging/components/ota/` exists** (not a Kconfig knob).
4. **lint**: reject any `idf_component_register(REQUIRES …)` that hand-writes a known straddle
   repo name — cross-straddle deps MUST flow through `${SPANGAP_REQUIRES}`.
5. `idf.py build` (which drives the browser build).
6. on a successful plain build, write **`build/flasher.zip`** — `flasher_args.json`
   plus every image it references (bootloader, partition table, app, data). A
   self-contained, host-independent bundle any flasher consumes: the web flasher
   (`spangap/flasher`), or `spangap make-builds` collecting it into a builds repo.

Consumer CMake idiom: `include(${CMAKE_CURRENT_LIST_DIR}/spangap_requires.cmake)` then
`REQUIRES ${SPANGAP_REQUIRES} …`. The buildable's `main/CMakeLists.txt` reads
`${CMAKE_CURRENT_LIST_DIR}/../staging/main_requires.cmake` — **`CMAKE_CURRENT_LIST_DIR`,
not `CMAKE_SOURCE_DIR`** (the latter breaks in IDF's requirements pre-pass).

**Boot registration (don't hand-wire bring-up in `app_main`).** The buildable ships no
`main.cpp` — `spangap-inside` generates the **entire** entry point into
`staging/spangap_init_dispatch.gen.cpp`: a `spangapRegisterServices()` that constructs every
staged straddle's boot object and appends it to one ordered registry (`serviceRegister`),
plus an `app_main()` that walks that registry twice — `serviceRunStart()` (bare hardware,
before `spangapInit()`) then `serviceRunInit()` (after, ecosystem up). Registration order is
`init_order()` (platform band core/net/web/lcd, then dependency-topo), so a straddle's deps
come up before it; you do **not** list any bring-up by hand.

A straddle contributes boot code two ways:

- **`services:` (modern).** Declare a `Service` subclass (spangap-core's `service.h`); it
  participates in a phase purely by overriding `onStart()` / `onInit()`, and the generator
  emits a per-straddle trampoline TU (`spangap_services.gen.cpp`) that `#include`s the class
  header and `new`s it. The class must be **global, external-linkage, default-constructible
  with an ecosystem-free ctor** (member init only — storage/fs/log/cli/ITS are not up when
  ctors run at the top of `app_main`). An `LcdApp` is a `Service`, so an on-device app is
  just a `services:` entry. Full contract: the `services` key in
  `schemas/straddle.schema.json` and spangap-core's `docs/init.md`.
- **`start:` / `init:` (legacy free-function hook).** Still supported — the generator wraps
  each `void xInit(void)` in an adapter `Service`. The symbol uses **plain C++ linkage** (the
  forward decl is `void xInit(void);` with no `extern "C"`), so an init defined in a `.c`
  file needs an `extern "C"` wrapper to match. **Caveat:** the schema's `init.call`
  *description* still says the symbol must be `extern "C"` — stale prose; the emitted
  C++-linkage decl is what links.

(This supersedes the long manual `app_main()` init sequences still shown in some sibling
READMEs — see the stale-doc caveats below.)

### Declarative settings (the `settings:` block)

A `settings:` block in a `straddle.yaml` is the **single source** for a settings pane;
`spangap-inside` lowers it into **three** surfaces at build time — LCD pane, web panel,
and storage defaults — written once, not thrice (search `collect_settings`,
`_settings_lcd_cpp`, `_settings_defaults_cpp`, `_settings_web_descriptors`). Prefer it
over hand-writing all three for any pane that's just static rows.

The block is a **list of panels**, each `{ menu: [{id, label, placement?}, …], rows: […] }`.
The `menu` segment carries **both** an `id` and a `label` because the two UIs address panes
differently: `id`s join into the **web** menu path (`settings/<id>/…`, also the container
merge key), while `label`s join into the **LCD** `lcdRegisterSettings` path. Row kinds:
`section` / `caption` (text), `switch{label,key}`, `slider{label,key,min,max}`,
`text{label,key,secret?}`, `dropdown{label,key,options:[{v,l}]}`, `value{label,key}`
(read-only live value), `button{label,cmd,payload?}` (payload defaults `"1"`), and
`list{key,item_label,add,remove,fields}` (array-of-objects).

The three generated surfaces:

- **LCD pane** → static `spangapGenPane_N(void*)` functions of `lcdSetting*` calls plus a
  `spangapSettingsGenRegister()` that wires them via `lcdRegisterSettings`, emitted into
  `staging/spangap_init_dispatch.gen.cpp` and called after the `serviceRunInit()` walk. The
  body is emitted **only when `spangap-lcd` is staged** (gated globally, not per-panel).
- **Storage defaults** → `spangapSettingsGenDefaults()` (also in that gen file), one
  `storageDefault()` per binding row (`switch`/`slider`/`text`/`dropdown`) that carries a
  `default:` **and** whose key is persisted config (`s.` prefix); the C literal type follows
  the YAML value's type. **Always emitted** (headless/web builds seed defaults too), and
  called after `spangapInit`, before the `serviceRunInit()` walk. Bare/ephemeral keys and
  secrets are never seeded.
- **Web panel** → a JSON descriptor inlined into `<browser>/src/boot/straddles.gen.ts` as
  `GENERATED_PANELS`; `registerGeneratedPanels()` (`spangap-web`'s `lib/generatedPanels`)
  registers each at its menu path against **one shared** `GeneratedPanel.vue` interpreted at
  runtime — no per-pane SFC codegen (a runtime-interpreted descriptor is far less fragile
  than generating Vue components).

**Escape hatch:** a panel with `web: false` suppresses only its generated web panel (the
straddle keeps a hand-written `*Panel.vue` at the same menu leaf for rich UI a static
descriptor can't express — WiFi scan, ACME, WireGuard, ssh); the LCD pane and storage
defaults still generate from the same block. **`list` rows are web-only to edit**: the web
side edits the array (`GeneratedListRow.vue`, mutations routed through the owning task's
`cmd` storage sentinels, never mutating the array from the UI), while the LCD pane just
shows a "manage this list in the web UI" caption (the core storage API exposes no array
*editor* to the LCD; a straddle can still surface per-item status via `value` rows).

Panel gating is purely **presence** — a panel appears iff its straddle is staged; there is
no per-panel `when:`. The schema lives in `$defs/settingsPanel` + `$defs/settingsRow` of
`build-system/schemas/straddle.schema.json`. Many straddles already carry a `settings:`
block (enumerate with `grep -l '^settings:' <workspace>/*/straddle.yaml`); don't assume a
fixed converted-set. `storageSet` is **async** (it queues to the owning actor) — rely on
operation ordering, not an immediate read-back.

## Editing the build system from inside this container

**The `spangap` you run is baked into the image.** The Dockerfile `COPY`s
`build-system/spangap-inside` → `/usr/local/lib/spangap/cli.py`. So editing the source
under `<root>/spangap/build-system/spangap-inside` changes the **source**, not the
running CLI — your edit won't take effect via `spangap …` until the image is rebuilt
(which happens host-side: `spangap-outside` notices the `build-system/` content hash
diverged from the image's `org.spangap.buildsys-hash` LABEL and rebuilds on the next
host command).

To **test an edit to the in-container CLI without a rebuild**, run the source copy
directly (the spangap repo lives at `<workspace>/spangap`) with the **system**
interpreter `/usr/bin/python3`:

```sh
/usr/bin/python3 .../spangap/build-system/spangap-inside validate   # or list-requires, build, …
. "$IDF_PATH/export.sh"                                              # ONLY for build/flash — see below
```

Use `/usr/bin/python3` explicitly, **not** a bare `python3` after sourcing
`$IDF_PATH/export.sh`: `export.sh` puts the **IDF venv** python first on PATH, and that one
lacks the CLI's pip deps (`jsonschema`, `pyyaml`). The system `/usr/bin/python3` is where
those deps were installed. Source `export.sh` only for the subcommands that actually shell
out to the toolchain (`build`, and flash which needs esptool via the toolchain env) — the
read-only verbs (`validate`, `list-requires`, `list-deps`, `show`) don't need it. The source
file has **no `.py` extension** and is loaded via `importlib.machinery.SourceFileLoader`.

**The schema is baked too.** The manifest schema is `COPY`d to
`/usr/local/share/spangap/straddle.schema.json` (root-owned), and `spangap-inside` reads it
via `SCHEMA_PATH`, which honours **`SPANGAP_SCHEMA_PATH`**. So when you edit the manifest
schema under `build-system/schemas/` and want the running CLI to see it before a rebuild,
point at the source copy — `SPANGAP_SCHEMA_PATH=.../schemas/straddle.schema.json spangap
validate` — otherwise the baked schema rejects any manifest key your edit just added (the
same applies to `flash`/`cli`/`log` once a manifest gains a new key).

`spangap-outside` (POSIX `/bin/sh`) and the Dockerfile are **host-build-time**
artifacts — editing them here is fine, but they only matter on the host / at the next
image build, never to the currently-running container.

## Helping write or maintain a straddle

1. **Manifest** — `straddle.yaml` with `name`/`prefix`/`version`; pick `prefix` with
   care (symbol prefix *and* browser import name — check it's free in the namespace map
   above). If the straddle has bring-up code, declare a **`services:`** class (or a legacy
   **`init:`**/**`start:`** hook, C++-linkage, no `extern "C"`) so the generated boot
   registration constructs and runs it in dependency order — don't expect the app to
   hand-call it. Check with `spangap validate`.
2. **Deps** — hard → `requires`; integrate-when-present → `additional_installs`, and
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

## Writing straddle docs

The docs of every straddle follow one standard: two roles — an **operator guide**
and a **maintainer reference** — laid out by how much the straddle does. (`rns` is
the reference end-state.)

**Mono-function straddle (most):** exactly two files at the straddle root —
`README.md` (operator guide) and `INTERNALS.md` (maintainer reference). If a
section grows big, it's a section, not a new file.

**Multi-function straddle (`spangap-core/-net/-web/-lcd`):** a thin index
`README.md` (what's here, pointing at each function's doc — *not* the operator
guide for every function) plus a `docs/` pair **per function**: `docs/<func>.md`
(operator guide) and `docs/<func>-internals.md` (maintainer reference), each
linked from its `<func>.md`. Internals are a separate file, not a trailing
chapter, so a context reading one doc doesn't load the whole maintainer
reference. No root `INTERNALS.md` in these straddles. `docs/` exists **only**
for this pattern — one self-contained file per function, never arbitrary
per-subsystem fragmentation.

**Operator-guide shape** (a mono README or a `docs/<func>.md`): one-paragraph
what-it-is; brief origins (wraps/forks/ports what — detail goes to internals);
what it does and how it interacts with the other straddles, with one minimal
real usage example; the public surface (ports/API/opcodes, pointer to the header
for exact layouts); the **full storage-variable list** (settings with defaults,
runtime/telemetry, command sentinels, secrets — exhaustive, verified against
code); CLI / user manual. Never tell users to call an `xInit()` the generated
init already calls — state that it starts automatically when the straddle is in
the build.

**Maintainer shape** (an `INTERNALS.md` or `docs/<func>-internals.md`): §1 first —
an exhaustive inventory of everything changed/added relative to the
upstream/baseline; then task/threading model and ownership rules, wire/IPC
framing, lifecycle, and a dedicated pitfalls section. Self-authoritative.

Hard rules:

- **A straddle's docs live in that straddle.** Never document straddle A inside
  straddle B; fold a stray doc into the owner and retire it.
- **No plan file is documentation.** `plans/*` is scratch history; docs stand on
  their own and never link into plans.
- **Settings ownership is declarative** — a doc never re-defines a config key or
  default owned by another straddle's `settings:` block; the owner documents it
  fully, everyone else points at the owner.
- **Describe the present, not the path to it.** Cut plan phases, "used
  to"/"previously"/migration history, dated status prose, plan-only facts not in
  code, and header restatements. Keep current true behavior/contracts, the
  complete verified surface, architecture and ownership/threading rules,
  pitfalls (a historical one only as the rule — "X must be Y, because Z" — not
  the anecdote), and rationale for non-obvious decisions stated as present fact.
  This applies to code comments, CLI help, and log strings too.
- **Use the real vocabulary** — upstream/protocol terms and existing platform
  names; don't coin words that collide with a platform primitive's term. Rename
  across code, comments, and docs in one pass, verifying zero stragglers.
- A genuinely cross-cutting, multi-straddle architecture doc is not one
  straddle's doc — it stays separate.

Overhaul process, when consolidating or retiring docs: gather all sources (stray
`.md`, comments, headers, history); write the standard files; **coverage-audit
before deleting anything** — walk every fact/key/opcode/CLI command/pitfall in
the material to be deleted and confirm it's either reflected in the new docs or
genuinely stale (verify each value against live source, not against a plan or an
older doc; watch for keys hidden behind macros and for `#if 0`'d/stubbed code —
don't document those as live). Classify what you drop (stale / plan-only /
domain-foreign), fix dangling references, and retire superseded files by
renaming to `*.old.md` — never hard-delete — only after every receiver has
absorbed them.

## Container gotchas

- **No serial, no docker, no esptool in here** — flashing/monitoring is host-side; from
  here `spangap flash` only signals via `.spangap-flashme`, and you read the device through
  the host monitor's `.spangap-log` (both at the workspace root; see "Working with a real
  device").
- **On macOS Docker Desktop, `fakeowner` shows every file mode 0755**, which makes git
  report spurious `100644→100755` flips. Straddle checkouts set `core.fileMode false` —
  leave it; don't "fix" the mode noise or chmod to silence it.
- **The running `spangap` is the image copy**, not the source tree (see "Editing"
  above). Don't expect source edits to take effect through `spangap …` without a rebuild.
- **Missing transitive deps are fetched host-side** into `<workspace>` — a missing
  required straddle triggers a git clone, not an error.
- **`reallyclean` is workspace-wide** — it reaches across *every* straddle in the
  workspace, but only removes gitignored, regenerable output.

## Stale-doc caveats (the sibling READMEs are mid-rewrite — don't trust these bits)

The straddle READMEs were recently rewritten and several carry `README-old.md` and
superseded per-straddle `CLAUDE.md` files. Four concrete traps when reading them:

- **The flat layout is real; the `s/` paths in docs are not.** Some READMEs (notably
  `hw-tdeck`) link siblings as `../../s/spangap/INTERNALS.md` or
  `[…](../../s/)`. There is **no `s/` directory** — `<workspace>` is flat,
  as this file's tree shows. Resolve any `s/`-style link to `<workspace>/<repo>/…` directly.
- **README file-layout boxes are partly aspirational.** The org-profile README and
  `spangap-core` README describe the spangap repo as `cli/spangap`, `install/spangap`,
  `scripts/`, etc. The **actual** tree is `build-system/{spangap-inside, spangap-outside,
  Dockerfile, schemas/}` + the `spangap` shim — no `cli/`, `install/`, or `scripts/`.
  Trust this file and `ls` over those boxes.
- **Per-straddle `CLAUDE.md` files are superseded.** Any content that used to live in a
  straddle's `CLAUDE.md` moved into its `README.md`, its `INTERNALS.md` (per-straddle + the
  platform-wide `spangap/INTERNALS.md`), and `spangap-core/docs/` — prefer those as canonical.
- **The hand-written `app_main()` init sequences are obsolete.** READMEs that show
  `pmInit(); logInit(); fs_init(); …` enumerated by hand predate boot registration; today
  `app_main` is fully generated — service registration plus the two registry walks (see
  "Boot registration" above).

Platform realities not stated elsewhere in this file, but assumed everywhere: target is
**ESP32-S3 with octal PSRAM (mandatory)**, toolchain is **ESP-IDF 5.5.4** + Node 20.
The PSRAM/DRAM split is a live firmware hazard — a flash op disables the PSRAM cache, so
a task on a PSRAM stack that touches LittleFS **crashes**; route all I/O through the
`fs_*` API (the reason `fs.cpp`'s DRAM worker tasks exist). DMA/WiFi/lwIP need internal
DRAM.

## Read next

- [INTERNALS.md](INTERNALS.md) — staging/gating internals, the rejected alternatives,
  ITS/storage/recipes, full gotcha list.
- [../spangap-core/README.md](../spangap-core/README.md) + [../spangap-core/docs/](../spangap-core/docs/)
  — firmware/browser code map and subsystem deep-dives.
- [README.md](README.md) / [CONTRIBUTING.md](CONTRIBUTING.md) — host install story; DCO sign-off
  (`git commit -s`, enforced by `.github/workflows/dco.yml`).
</content>
