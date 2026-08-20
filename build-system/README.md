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
  names that board straddle (e.g. `--with spangap/hw-lilygo-tdeck`). If `.spangap-build` is
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
| `spangap build [-v] [-w/--with <straddle>] [-x/--without <straddle>] [--no-lcd/--no-web/--no-net] [--flash-size MB] [--kconfig CONFIG_X=y] [idf args…]` | resolve deps → stage → lint → `idf.py build` (+ browser build). `--kconfig` (repeatable) forces a Kconfig value for this build — the way a build **flavour** is expressed, where a board's own hardware values belong in its `kconfig:`. It lands in `staging/sdkconfig.spangap-overrides`, the highest-priority `SDKCONFIG_DEFAULTS` entry, and `bootstrap.cmake` reseeds `sdkconfig` when that set changes, so switching flavours in one tree needs no clean (unless `.spangap-manual-kconfig` is set — then the reseed is skipped and the flavour silently doesn't apply). Remembered in `.spangap-build` with `--with`/`--without` |
| `spangap web [-w/--with <straddle>] [-x/--without <straddle>]` | regenerate the browser half only (`src/boot/straddles.gen.ts`, `src/app-icons/`, the `file:` deps in `package.json`, `npm install` if those changed) — no IDF compile. Bare, it uses the remembered build's straddle set |
| `spangap menuconfig [--save]` | interactive Kconfig editor (`idf.py menuconfig`) over the staged project; `--save` writes the minimal `sdkconfig.defaults` (the "configure a board straddle, save as `hw-whatever`" step) |
| `spangap autoconfig` | leave manual-kconfig mode (drop `.spangap-manual-kconfig`) and reseed `sdkconfig` from `sdkconfig.defaults` on the next build |
| `spangap validate` | parse + jsonschema-check the manifest and dep graph (fast, read-only) |
| `spangap list-requires` / `list-deps` | full transitive set / missing siblings (read-only diagnostics) |
| `spangap clean` / `reallyclean` | `idf.py fullclean` / strip **every** straddle in the active root back to source (gitignored artifacts only) |
| `spangap show` | project straddle + deps in init order, the env report (python, IDF_PATH, node/npm/idf.py versions), and whether a host `spangap monitor` is ready to flash (bare `spangap` with no subcommand does the same; `show` stays as an explicit alias) |
| `spangap cli [-h host] [<cmd>]` | talk to a running device over the network (ssh, else TCP CLI) |
| `spangap flash` | **signal only** — touches `.spangap-flashme` (workspace root) and waits ≤5s for a host monitor to consume it (see below) |
| `spangap reset` | **signal only** — touches `.spangap-resetme` (workspace root) and waits ≤5s for a host monitor to consume it; the monitor restarts with a device reset (clean reboot + boot-log capture), no reflash |
| `spangap make-builds [entry…]` | build the image catalogue described by the `builds.yaml` in the cwd (or every catalogue below it), stamp every image of the run with one datetime, rewrite `index.html` + `timestamp`. Every straddle it compiles must already be in the workspace — cloning is the host's (see below) |
| `spangap log [-f]` | print the device serial log (`.spangap-log`); streamed from the host monitor's relay (`host.docker.internal:2324`) because the bind mount is stale inside the container (a plain `cat`/`tail` — and even `O_DIRECT` — freeze; see below); `-f` follows like `tail -f` and survives flash/reset truncations |

**`spangap flash` / `spangap reset` / `spangap cli` from in here don't touch hardware
directly** — the
container has no USB. `flash`/`reset` only signal a host monitor; `cli` reaches the device
over the network. `spangap cli "<cmd>"` runs an **arbitrary** device CLI command and returns
its output (`spangap cli gps`, `spangap cli "set s.gps.interval=5"`) — combine it with
`spangap log` to verify firmware autonomously. The container **cannot route to the
device's LAN address itself** — raw sockets reach the device only through the host-side
relays at `host.docker.internal:<port>`, which front the device's well-known ports (ssh
`:22`, web `:80`/`:443`, TCP CLI `:2323`) plus any extra ports the project's straddle.yaml
declares in `bridge_ports:` (a one-line flow list, e.g. `bridge_ports: [7633]` — the host
reads it with a sed, so a block list is invisible). The relays belong to whichever of
`spangap monitor` / `spangap dev` is running, so a `bridge_ports:` change takes effect on
that verb's next start. One trap: the relay accepts a connection *before* dialing the
device, so a successful connect proves only that the relay is up — a dead device port
looks like an accept followed by silence, then a close. Physical checks and anything
serial-interactive stay user-driven. The full
device loop is its own section below
([Working with a real device](#working-with-a-real-device--the-you--user--board-loop)).

**Host-only verbs you can't run from this container:** `monitor`, `probe`, real
`flash`, `init`, `reset-workspace`, `get-deps` (the cloning side), `push-all`
(create + push every straddle repo to GitHub — runs `gh`/`git` with the host's
credentials, never in the container), `detect-build`
(build flashmon's `esp-idf/` peripheral
detector in the container), and `docker <cmd>` — those
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

### `install-reticulum` — the reference Reticulum stack

`install-reticulum` is on PATH in every container (a plain script, **not** a
`spangap` verb). Run it as `spangap` to install the upstream Python Reticulum
stack (`rns` + `rnsh`) into `~/.reticulum-venv` and wire it to the
**rns.beleth.net:4242** uplink, ready to use. It is idempotent — re-run it to
refresh the install, the uplink address, and the patch below.

Afterward `rnsd`, `rnsh`, `rnstatus`, `rnpath`, `rnprobe`, `rnid`, `rncp`, `rnx`
are on PATH (symlinked into `~/.npm-global/bin`) and use `~/.reticulum` (the RNS
default config dir), so they take no `--config` flag. `hash -r` or a new shell
picks up the links. Sanity check: `rnstatus` should show `beleth-uplink` **Up**.

Two things the script handles that are easy to trip over:

- **Uplink address family.** beleth publishes both an A and an AAAA record, and a
  given container may only egress on one family. RNS's `TCPClientInterface` tries
  only the first `getaddrinfo()` result and never falls back, so the script
  probes both and writes the literal that actually connects (IPv4 preferred,
  IPv6 fallback). This is why the config holds an IP, not the hostname.
- **rnsh listener auth-bypass patch.** Upstream `rnsh`'s
  `ListenerSession._initiator_identified()` rejects a disallowed initiator with
  `terminate()` but omits the following `return`, so it falls through to
  `_set_state(WAIT_VERS)` and the session goes on to accept a command and spawn a
  shell in the window before the pruning timer fires. The script adds the missing
  `return` (and the one after the out-of-state `_protocol_error`) so a rejected
  identity is actually stopped. Our firmware `rnsh` does not share this flaw — it
  runs no identity allowlist and gates every session on the server-side `cli`
  admin-password login, which dispatches no command until `authLogin` succeeds.

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

`spangap monitor <port> --aux <dev>` additionally fronts a **second** serial
device on the bridge at `host.docker.internal:2325` (`$SPANGAP_AUX_PORT`) —
bytes both ways, no line state — for an in-container client that needs a device
serial port the monitor itself doesn't hold (e.g. the spare CDC port while the
console is on `usb cdc`). Sticky like the port; `--aux -` clears it.

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

**3. Drive the device over the network.** `spangap cli [<cmd>]` reaches the device through
a **host-side relay** (the container can't route to the device's LAN, so on Docker Desktop
it dials `host.docker.internal` and the host splices to the real device; native Linux
reaches the LAN directly). Two verbs put that relay up, each for as long as it runs and no
longer: `spangap monitor`, which opens its bridge on start and closes it on exit, and
`spangap dev`, which brings up its own set (see above) so a dev session needs no monitor —
which is the point, since the monitor holds the serial port. One workspace-root file names
the device:

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

**`spangap dev [<addr>]`** runs the project's Quasar web SPA (`web-interface/`) hot from
Vite, reachable from outside the container at **`http://localhost:9000/`**, which it opens
in the OS browser. The address argument (bare, or `-h <addr>`) sets the device this run
drives, and persists it like `spangap cli`. It streams the dev console until you quit it.

**The run owns every relay it needs, so nothing else has to be running.** That matters
because the alternative — the `spangap monitor` bridge — holds the serial port, and the
browser flasher this same dev server serves at `/flashmon` wants that port itself. On
startup it brings up one `dev-forward` process holding:

- the **dev server's own** relay: the container publishes its dev port to an ephemeral host
  port (a fixed publish would hold that port for the container's whole life and wedge every
  other workspace), and this fronts it on 9000 — or the next free port up, so a second run
  lands on 9001 instead of failing;
- the **device's** relay on a port private to this run, which is what the container's proxy
  dials at `host.docker.internal` (Docker Desktop can't route to the LAN segment) — private
  so two runs can serve two different devices at once;
- the device's **well-known ports** (443, 80, 22, 2323), best-effort: whichever are free,
  so in-container `spangap cli` reaches this device too. A port already taken is skipped —
  the first run to want it gets it.

Everything is torn down when the run exits. Concurrency is bounded by the container's
published dev-port range (`9000-9009`), one port per concurrent run in a workspace; a
container from before the range is recreated to get it.

On a native-Linux host the container reaches the LAN directly, so the proxy dials the device
address itself and the relays are just unused.

It also mounts two workspace directories beside the app, at the paths a deployment serves
them at: **`/flashmon`** (`flashmon/flashmon/`, the browser flasher) and **`/builds`** (the
image catalogues). Each `web-interface`'s `quasar.config.ts` asks for them by adding
`spangap-browser/vite/workspace-mounts` to `build.vitePlugins`; Vite has one static root,
so extra trees can only be middleware.

**Browser-side edits need no build.** The dev server runs Vite in the buildable's own
`web-interface/`, and every straddle browser half is an npm-linked `file:` dep served as
live source (`quasar.config.ts` keeps them out of dep pre-bundling for exactly that
reason), so editing `web-interface/src/` or any `<straddle>/browser/src/` is picked up by
HMR while `spangap dev` runs. Only the *generated* inputs — `src/boot/straddles.gen.ts`
(registration dispatcher + declarative settings panels), `src/app-icons/`, and the `file:`
deps in `package.json` — come from a build, and **`spangap web`** rewrites just those with
no compile: run it after changing a `browser_register:`/`settings:` block or the staged
set, and the running dev server reloads on the generated file. A full `spangap build` is
needed only when the firmware half has to change too.

**`spangap make-builds`** builds an image catalogue: run it in a `builds/<catalogue>/`
directory holding a `builds.yaml` (or in the tree above them, for all of them). Every image
of one run shares one datetime stamp, and it rewrites the `index.html` + `timestamp` that
the flasher reads. Each image is a `spangap build`, run from in here like any other. Each is
built with `SPANGAP_BUILD_DATETIME` (that stamp), `SPANGAP_BUILD_DIST` (the entry's `name:`) and
`SPANGAP_BUILD_CATALOGUE` (the directory's own name) in its environment, so the running
firmware reports back which catalogue published it and when — `sys.build.catalogue` /
`sys.build.datetime`, and a `build: catalogue <name>` line in the boot log.

**Every straddle a run compiles has to be in the workspace already.** Cloning one takes the
host's git credentials, which this container has none of — so the host half of `spangap`
reads the run's invocations first (`spangap make-builds --invocations`, a read-only parse of
the `builds.yaml` under the cwd) and puts each of them through the same clone + `list-deps`
loop a plain `spangap build` gets, before handing the run in here. A target still absent by
then is a fault rather than something to fetch: the run pre-flights every entry's target,
stops before building anything, and names the straddle together with the catalogue entries
that want it — clone it from the host (`spangap build <org>/<repo>`, `spangap get-deps`) and
re-run.

**A clean run prints nothing but its report** — one `Catalog:` line per catalogue and one
indented line per image, with each build's output (and the toolchain's under it) captured
rather than streamed:

```
Catalog: stable
  reticulous/reticulous --with spangap/hw-lilygo-tdeck --kconfig CONFIG_LORA_NO_SUPE=y ... done (3.4 MB)
```

On a failure that suppression lifts — the failing build's captured output is printed in
full, the run stops there, the listing is still rewritten from what is on disk, and the exit
status is non-zero.

**`spangap make-builds <entry> [<entry>…]`** — inside one catalogue — builds only those
entries. The listing is still rewritten, from **what is on disk**: the boards you didn't
name keep their previous images and stay listed at their old stamps, so a one-board rebuild
publishes that board and disturbs nothing else. (Naming entries only works inside a single
catalogue; a run over the tree above them refuses it.)

A built entry's **older images are deleted** once the new one is in — same entry, same
catalogue, earlier stamp. One entry in one catalogue means one image: the flasher only ever
offers the newest per name, so the rest are download weight in the deployment and noise in
the listing. Only entries a run actually built are pruned, and only strictly older stamps,
so a subset run still leaves every other board alone. A build that fails prunes nothing —
the image that is still the current one stays where it is.

A catalogue directory holding a **`.unlisted`** file still builds and is still reachable by
naming it on the flasher page (`?build=<name>`, or the settings panel's Build selector) — it
is simply left out of the parent `index.html`.
Catalogues differing only in flavour say so with `--kconfig` in their entries, so they build
from the same tree with no straddle per combination.

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
call sites **must** gate on `CONFIG_*`; an entry is a plain spec or
`{ install:, when: }`, staging `install:` only when the `when:` straddle is
also in the closure — e.g. spangap-lcd pulls lcdmirror only into builds that
already have spangap-web); `firmware:` / `browser:` (paths to the two
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
| | | `hw-lilygo-tdeck` | `tdeck` |

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
6. on a successful plain build, write **`build/flasher.zip`** — `<project>.esptool` (an
   esptool argfile: the write_flash flags, then `<offset> <image>` per line) plus every
   image it names (bootloader, partition table, app, data). A self-contained,
   host-independent bundle any flasher consumes: the web flasher (`flashmon`), or
   `spangap make-builds` collecting it into a catalogue. The argfile is generated from
   `flasher_args.json` rather than copied from IDF's own `flash_project_args`, because the
   in-place finalize patches the `fixed` offset into the former only.
   The SPI-flash flags are written short — `-fm dio -ff 80m -fs 16MB` — the one spelling
   every esptool takes: esptool 4 knows only `--flash_mode`, esptool 5 renamed it to
   `--flash-mode` and keeps the underscore form as a deprecated alias it warns on and drops
   at the next major. So `esptool ... write_flash "@<project>.esptool"` runs clean on any
   version, and the file carries no comments (esptool `shlex.split`s each line and does not
   strip `#`).

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

Each registration also carries a `service_band_t` derived from that same order (`SAFE_BAND`
in `spangap-inside`): core/net/web/lcd get `SERVICE_BAND_SAFE`, everything else
`SERVICE_BAND_FULL`. A **safe-mode** boot — the recovery boot that backs the state store up,
restores one, or factory-resets the device — runs the SAFE band only. No straddle declares
this and none can opt in or out; it is a property of where it sits in the order. The screen is
in the band because a wipe can take minutes and the panel is where an operator looks to find
out whether the device is working; it touches no store, reading an ephemeral percentage and
drawing. See spangap-core's `docs/safe-mode.md`.

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

The `settings:` blocks across a build describe **one tree**, and `spangap-inside` lowers
that tree into **three** surfaces — LCD nodes, browser nodes, storage defaults — written
once, not thrice (search `collect_settings`, `_settings_lcd_cpp`, `_settings_defaults_cpp`,
`_settings_web_nodes`). It is expressive enough for a whole pane, editors and confirmation
flows included; hand-writing a settings pane is now the exception that needs a reason.

**The tree.** Every node holds key/value **rows** *and* **children**, rendered rows first
and children after as navigation entries. There is no leaf/container distinction and **no
node is owned**: a contribution names a path with `at:`, every intermediate node on the way
is conjured, and two straddles contributing at the same path simply concatenate their row
blocks. A node's path is its stable id on both surfaces. By convention the root holds only
children.

A node with **no rows and no non-empty descendant is not rendered** — no navigation entry
on either surface, nothing to walk into. So declaring a node is not the same as putting it
on the screen: a straddle may name a top-level menu and give it an order while leaving it
empty, and the menu appears the moment something contributes to it. That is what lets the
main menus be named in one place each (see below) instead of repeated by every contributor.

**Sections merge.** Blocks concatenate, but their **sections** do not: a second straddle
writing `section: "Status"` at a node that already has one does not get a second heading —
its rows land at the end of the existing section's rows. Rows written before any section
join the headerless run at the top of the node. Two straddles describing the same subject
therefore arrive under one heading instead of beside each other, which is what a node
nobody owns is for. The match is exact (a case-only near-miss stays two headings, with a
build warning), and it resolves here, at lowering time: each runtime receives a node's
rows as one opaque builder, so the generator is the last place that still has the rows
themselves. The consequence to know is that a straddle's rows can end up split across the
pane — the section a row sits under is where it goes, not where it was written.

```yaml
settings:
  - at:
      - { id: net, label: "WiFi & Network", short: "Network", order: 10 }
      - { id: wifi, label: "WiFi" }
    rows:
      - switch: { label: "Enable", key: s.wifi.enable, default: 1 }
```

Each segment carries `id` (the lowercase slug — the merge key), and optionally `label`
(long name), `short` (the LCD header; defaults to the label) and `order`. Naming is **last
setter wins**, per field, in straddle init order — so the buildable, which arrives last of
all, always has the final say over the tree its image ships. A node nobody names falls back
to its title-cased id.

**Naming a menu is a convention, not a claim.** Nothing stops a straddle from labelling or
reordering a node somebody else set up, and the merge does not warn about it. What keeps
the tree coherent is that each menu is named **once**, by the straddle it exists for, while
every other contribution states the bare `id:` it lands at. The four top-level menus of a
reticulous image are named that way:

| menu | id | order | named by |
| --- | --- | --- | --- |
| WiFi & Network | `net` | 10 | `spangap/spangap-net` |
| Reticulum Mesh | `reticulum` | 15 | `reticulous/reticulous` (the buildable) |
| Apps | `apps` | 20 | `spangap/spangap-core` |
| System | `system` | 30 | `spangap/spangap-core` |

Two of those are named by a straddle that contributes no rows to them at all — a bare `at:`
with no `rows:` is a legal contribution, and with the empty-node rule above it costs
nothing when nobody fills the menu in.

**Ordering.** Anything with siblings — nodes, rows, row blocks, a collection's add
entries — may carry `order:` (an integer). One rule everywhere: items with `order:` first,
ascending; everything else after them, in (straddle init order, declaration order). Init
order is `init_order()` (platform band, then dependency topology), so platform
contributions naturally precede consumer ones. This is resolved **at lowering time** — the
generator knows init order, so it emits contributions pre-sorted and the runtimes only need
stable insertion.

**Two firmware conventions** carry as much weight as the schema, and a pane that fights
them will need code:

1. **Firmware publishes finished strings.** Any derived display value — signal-quality
   wording, a composed traffic counter, a formatted percentage, a capability's yes/no — is
   published to an ephemeral key as the exact text to show. No UI computes, compares or
   concatenates. Gate keys are published truthy/empty, and `when_key` tests truthiness
   only, never equality.
2. **Firmware validates in sentinel handlers, and answers on two keys.** A mutation
   arrives on a command-sentinel key; the owning task validates it and answers on the
   sentinel family's shared **error** and **ack** keys — for a collection that is
   `<cmd>.error` / `<cmd>.done` (one pair for `.add`/`.set`/`.remove`/`.order`), for a
   bare form `<form-cmd>.error` / `<form-cmd>.done`. A rejection is a human-readable
   sentence on the error key (the form shows it and stays open); an **accepted** mutation
   bumps the ack key (the form closes). The ack is a monotonic per-boot counter kept in a
   local variable — never a read-increment of the key, because storage writes are applied
   by the actor asynchronously and a read may still see the previous value. The UIs clear
   the error key immediately before each submit (in order, on the same actor), so a
   rejection identical to the last one still registers as a change past the actor's
   write-dedup. Submit-and-error replaces per-keystroke validation everywhere; every
   handler behind a form **must** implement both halves, or the form hangs open on
   success with nothing to close it.

   **Sentinel keys are ephemeral and live beside the values they manage, never beneath
   one.** A dot-path write under a scalar key replaces the scalar with an object,
   destroying it — so a sentinel updating `s.ntp.tz` is `ntp.tz.set`, not
   `s.ntp.tz.set`. A sentinel's `cmd:` is a fixed key, not a template.

**Row kinds.** `section` / `caption` (text), `switch{label,key}`,
`slider{label,key,min,max}`, `text{label,key,secret?,placeholder?,placeholder_key?}`,
`dropdown{label,key,options:[{v,l}],searchable?}`,
`timezone{label,field,placeholder_key?}` (an IANA zone picker, form fields only:
optionless in the yaml, because each surface brings its own list — the browser
its Intl database as a type-to-filter select, the LCD region+zone dropdowns from
the firmware's built-in zone table; `placeholder_key` names the key whose value
seeds the initial selection, and the submitted name must go through a sentinel
that resolves it against that table before storing),
`value{label,key,copyable?}`
(read-only live text), `button{label,do,color?}`, `buttons{align?,items:[…]}`,
`info{rows:[…]}`, and `list{…}` (a collection, below).
Every row may carry `order:`, `when_kconfig:`, `when_key:` and `when_surface:` **beside**
its kind — the same placement for all three gates:

```yaml
      - value: { label: "Address", key: wifi.addr, copyable: true }
        when_key: "wifi.up"
```

`when_key` is purely runtime: both surfaces subscribe, and the row exists while the key is
truthy. Inside a form or an item editor the key may be a `{field}` template referencing a
sibling field (`when_key: "{dhcp}"`), which is answered from the local buffer instead.

A text row's **`placeholder_key:`** names a key holding the placeholder text, for a hint
only the device can supply — the MAC it would use if the field is left blank, the port it
would pick. It wins over a literal `placeholder:`, and like every other published string it
is shown verbatim.

Inside a form or an item editor a **`section:` / `caption:` text templates too**, over the
same local buffer (`section: "SSID: {ssid}"`), and tracks the field as it is edited. That is
how an editor says which item it is editing without the surrounding pane having to.

`when_surface: web` (or `lcd`) emits the row on **one** surface only. It is for a row whose
action does not exist on the other: backing up and restoring hand an archive between the
device and the machine that pressed the button, and a display has nobody on the other end
of that. Unlike `when_kconfig` it leaves the storage defaults alone — the key is still the
device's, it is just shown in one place. It is a **pane-row** modifier: a form field, an
`info:` line and a collection's editor row are part of one control and go wherever that
control goes. On a `section:` row it gates the heading, which is how a heading and its rows
are stated together.

A gate on a `section:` row survives the section merge below: the **first** writer's heading
row is the one emitted, gates and all.

**A row of buttons.** A `button:` spans its row, which is right for a single action and
wrong for two that are one choice. `buttons:` puts several on one line, each sized to its
label, gathered `left` (the default), `center` or `right`. A button may carry its own
`when_key`, gating that button and not the line — a hidden one leaves the layout and the
rest close up around it. Keep the labels short: the display wraps a line that does not
fit rather than clipping it, but a wrapped pair is a stacked pair.

```yaml
      - buttons:
          align: right
          items:
            - { label: "Create", do: { form: { … } } }
            - { label: "Import", do: { form: { … } } }
```

**A block of readouts.** A run of `value` rows is a readout, not a list of settings, and
the row layout — a third of the pane for the label, whatever the longest label in the pane
needs — leaves it full of gaps. `info:` groups them: one shared label column sized to the
widest label in the GROUP and never wider than that third, and no gap between the lines.

```yaml
      - section: "Status"
      - info:
          rows:
            - value: { label: "Status", key: wifi.sta.state_text }
            - value: { label: "IP", key: wifi.sta.ip, copyable: true }
              when_key: wifi.sta.up
```

Read-only `value` rows only — a switch or a slider needs room the narrow column cannot
give, so anything interactive is an ordinary row above or below the group. The group has
no heading of its own on purpose: a `section:` row above it is the heading, which also
lets several groups sit under one. A line may be `when_key`-gated, and the column is
measured over every line including the hidden ones, so a line appearing never shifts it.
A gate on the `info:` row itself hides the whole group.

**Colour.** Anywhere a button is described — a `button:`, one of a `buttons:` row, a
dialog button, a collection's per-item action — `color:` states its colour, from the one
palette a status pill uses and through the same table on both surfaces: `red`, `green`,
`amber`, `blue`, `grey`, or an explicit `rrggbb`. So a red button is the red a red pill
is. State it only where the colour carries what the label does not, which in practice
means a destructive action.

**Actions.** Three kinds, accepted anywhere an action is (settings buttons, dialog buttons,
a collection's per-item buttons):

- **`set: {key, value}`** — write a key. `edge: true` writes `0` first, forcing a change
  past the storage actor's dedup (needed by flags that may be left set by an attempt that
  did not complete). `reboots: true` runs the shared reboot-wait behaviour afterwards — the
  web closes the session, waits and reloads; the LCD shows a modal notice. That absorbs the
  safe-mode entry flows as a named capability rather than per-panel choreography.
- **`dialog: {text, buttons:[{label, color?, do?}]}`** — confirmation or choice. **No
  input fields, ever.** Every button closes the dialog; a bare label is a cancel. Buttons
  nest actions, so a choice tree is dialogs of buttons of `set`s.
- **`form: {fields, cmd, submit?, title?}`** — the one dialog with inputs, because it fronts
  a sentinel. `fields` are ordinary binding rows carrying `field:` instead of `key:`; values
  are collected locally and serialized as one JSON object to `cmd` on submit. The handler's
  answer keys (convention 2 above) drive it: the error key showing a reason keeps it open,
  the ack key moving closes it — an edit that changes nothing still acks. A string
  `default:` on a field may be a `{field}` template over its siblings, tracking them until
  the operator edits that field. Prefill treats an **empty** stored field as unseeded, so a
  field with a `default:` shows the default again when its stored value is empty — give a
  field a default only where "empty" and "the default" mean the same thing.

Template substitution everywhere is `{field}` replacement only — no expressions, no
fallback chains, no slicing. Anything fancier is a string the firmware publishes.

A dropdown's option list is **static** — fixed at lowering time, no options-from-a-key.
A choice over device data (the timezone list is the case in point: a 600-entry file on the
device) is a `form` whose handler validates the submitted name, not a dropdown.

**Collections** (`list`) are arrays-of-objects with a full editor:

```yaml
      - list:
          label: "Peers"
          key: s.rns_tcp.peers      # per-field objects; packed strings don't bind
          id: host                  # the field identifying an item
          item: "{name}"            # row title
          subtitle: "{host}:{port}" # optional second line
          status: "rns_tcp.peer.{id}"   # ephemeral key holding packed "text|color"
          empty: "No peers configured."
          orderable: true
          cmd: rns_tcp.peer         # sentinel base
          add:  [ { label: "Add peer", form: { fields: [...] } } ]
          remove: { confirm: "Remove {name}?" }
          actions:                  # each may carry when_key, templated over the item
            - { label: "Connect", when_key: "rns_tcp.joinable.{id}",
                do: { set: { key: wifi.connect, value: "{id}" } } }
          edit: [ { text: { label: "Host", field: host } } ]
```

The UI **never mutates the array**. It writes `<cmd>.add` (a JSON item), `<cmd>.remove` (an
item id), `<cmd>.set` (the JSON item, plus `_id` naming the item it is committing against —
so editing the id field itself is an ordinary edit) and `<cmd>.order`; the owning task is
the array's only writer, answering every one of them on the shared `<cmd>.error` /
`<cmd>.done` pair (convention 2 above). An add form's `cmd:` defaults to `<cmd>.add`, so
the whole sentinel family stays derived from the one name. A handler consumes its sentinel
by deleting it (`storageUnset` / `storageDeleteTree`) after reading, which is what lets an
identical payload be submitted twice — a cleared key can't dedup the next write.

**On `.set`, absent is not empty.** A field the editor carries and the operator left blank
arrives as an empty string and erases what was stored — that is how a fixed IP is handed
back to DHCP. A field the editor does not carry *at all* is not being edited, and the
handler must fill it in from the item before validating or writing. That is what lets an
`edit:` block leave a field out: spangap-net's detail page shows the SSID in its
`section:` heading rather than as a row, and a handler that read absent as empty would
erase the SSID on every Save and then reject the entry for having none.

**Per-item secrets** stay out of the synced item object when they matter: the form carries
an ordinary `field:` with `secret: true`, and the handler routes that field to an
**id-keyed** side store (iface-tcp: `secrets.tcp.peer_ifac.<id>`) instead of writing it
into the item. Id-keyed, never slot-keyed — slots shift on remove and permute on reorder.
The field is write-only: the editor prefills nothing for it, and the handler treats an
empty submit as *unchanged*, so saving an untouched form never erases a secret. (A secret
the operator may freely read back — a WiFi password — can instead live in the item as a
plain `secret: true` field.)

`orderable` writes the complete id order to `<cmd>.order` as a comma-joined list — the
natural output of both a web drag-drop and an LCD up/down press. Firmware treats the payload
as a **preference permutation**: reorder recognized ids into that relative order, ignore
unknown ids, keep unmentioned ids in place. That makes it idempotent and benign under
concurrent edits, which is what lets the web list hold an optimistic order until the
re-published array lands.

The **item editor** (`edit:`) is the same mechanism as a form: a pane over a key scope, a
dialog on the web and a modal on the LCD, with every row feature available including
`when_key` over sibling fields and `{field}` templating in a `section:` heading.

On the **LCD it is the item's detail page**, and it is where everything that acts on one
item lives: tapping anywhere on a list row opens it, and it carries the `actions:` buttons
and Delete alongside Save and Cancel. A list row itself shows the item and nothing else —
title, subtitle, status pill, and the reorder arrows when `orderable`, because those are
about the row's place rather than the item. Five buttons on a 320 px row is a row nobody
can hit. The browser has the width for them and keeps them on the row.

An action's **`when_key`** is what takes a button off that page when it has nothing to do:
the template builds a KEY out of the item (`"wifi.netjoinable.{id}"`, unlike a row's gate
where a template names a sibling field's *value*), and the owning task publishes it truthy
on the items where the action applies. Hiding "Connect" on the network already connected is
therefore a key net.cpp sets on the others, never a comparison in a UI.

A **`candidates:`** clause turns a collection into scan-and-adopt: an ephemeral array the
task publishes, rendered like list rows, where picking one opens the first add form
prefilled (same-name fields map implicitly; `map:` is only for renames). `refresh:` is
required, because its button is how the list is reached: **both surfaces** open the results
as a popup, headed by `found:` (defaulting to the refresh label) — titled for what is on
screen rather than for the button that opened it, since by then the asking is done — and
dismissed by a small Close in its top-right corner, because a card that is one long list has
no room for a row of buttons under it. Opening the popup starts the scan and closing it
stops the scan. What the device can *see* is a transient answer to a question
just asked — it arrives over seconds, it changes, and it is gone once you stop asking — so
it gets its own screen rather than pushing the configured list around underneath a button
that may be well below the fold. Runtime contract: closing the popup, or leaving the pane,
**clears the `refresh` target key**, so no straddle carries a visibility timer for "stop
scanning on leave".

A slider's `min`/`max`/`default` may also be `{ kconfig: CONFIG_NAME, default: N }`:
resolved at lowering time from the staged set's collected `kconfig:` fragments
(`collect_kconfig_values`, same precedence as the fragment file), so a **board** can size
a control to its hardware. The `default` applies when no staged straddle sets the symbol
(component-Kconfig defaults are invisible to the generator).

A slider's `min`/`max` — not its `default` — may instead be
`{ key: <storage key>, default: N }`: the bound is read from a value the **device**
publishes, when the row is built on the LCD and reactively on the web. Reach for it when
the real limit is something the firmware determines and the build cannot: a capability
sensed on the hardware rather than declared for it. iface-lora's TX-power slider is the
case in point — the board's Kconfig declares a front-end module's rating, but only
`femInit` knows whether that part actually answered, so the slider is sized from what it
publishes and offers the bare radio's ceiling on a board whose front end is missing. The
`default` applies until the key exists.

**`when_kconfig: "CONFIG_X"`** (or `"!CONFIG_X"`) emits a row only when that symbol is set —
**all three surfaces at once**, so a build that gates a feature out has no row on the
display, no row in the browser, and no `storageDefault()` for its key: the key is absent
from storage rather than present and inert. It is resolved at generation time from the
same place a settings scalar's `{ kconfig: … }` reads — two sources, and only two:

- **the staged set's presence symbols**, `CONFIG_STRADDLE_<REPO>` and the
  `CONFIG_SPANGAP_<ALIAS>` short forms, the same ones the build declares for the compiler.
  This is how a row says it needs a *sibling straddle*: gps's motion-assist rows carry
  `when_kconfig: "CONFIG_STRADDLE_IMU"`, so they exist exactly in the builds that stage
  spangap/imu and nowhere else. The buildable itself has no presence symbol, in either
  half.
- **symbols straddles set in their `kconfig:` blocks**, which is where a build *variant*
  declares itself. iface-lora's `CONFIG_LORA_NO_SUPE` is the case in point: the same symbol
  gates the code with `#if` and these rows with `when_kconfig`.

Anything else reads as unset here even when the compiler sees it set from a buildable's
`sdkconfig.defaults` or from `spangap menuconfig` — so a feature meant to ship as a build
variant declares its symbol in a `kconfig:` block, the one place both halves of the build
can see it.

A hand-written panel has no such gate — one browser bundle serves either firmware — which
is one more reason a pane belongs in the yaml: `when_kconfig` is only available to a
description the build reads.

The three generated surfaces:

- **LCD** → simple rows stay **calls**: a `spangapGenSetPane_N(void*)` of `lcdSetting*`
  calls **per node** — one contribution per path, with every block at it already merged,
  which is what lets sections join — wired by `spangapSettingsGenRegister()` through
  `lcdSettingsContribute(segs, nsegs, fn)`, emitted into
  `staging/spangap_init_dispatch.gen.cpp` and called after the `serviceRunInit()` walk.
  Collections, forms and dialogs instead lower to **static descriptor structs**
  (`lcd_settings_desc.h`) consumed by generic runtime functions in
  `spangap-lcd`'s `lcd_settings_desc.cpp` — generating data rather than logic keeps the
  generated file small and puts the behaviour in one reviewable place. The body is emitted
  **only when `spangap-lcd` is staged** (gated globally, not per-contribution).
- **Storage defaults** → `spangapSettingsGenDefaults()` (also in that gen file), one
  `storageDefault()` per binding row (`switch`/`slider`/`text`/`dropdown`) that carries a
  `default:` **and** whose key is persisted config (`s.` prefix); the C literal type follows
  the YAML value's type. **Always emitted** (headless/web builds seed defaults too), and
  called after `spangapInit`, before the `serviceRunInit()` walk. Ephemeral keys, secrets
  and form fields are never seeded — a form field's `default:` is dialog prefill, not a
  value the device should hold before anyone submits one.
- **Web** → node-tree fragments inlined into `<browser>/src/boot/straddles.gen.ts` as
  `SETTINGS_NODES`; `registerSettingsNodes()` (`spangap-web`'s `lib/settingsNodes`) merges
  them into the `settingsTree` store, which one runtime renderer (`NodePane.vue`)
  interprets — no per-pane SFC codegen (a runtime-interpreted descriptor is far less
  fragile than generating Vue components).

**Escape hatch.** A pane a descriptor genuinely cannot express — one that draws, streams,
or is an application in its own right — still reaches the tree: the menu store forwards
`register('settings/…', {type:'panel', component})` into it as a component-typed row, and
it renders among the declared rows at that node. Every straddle in this workspace has been
converted, so the hatch is currently used only by out-of-tree apps (seccam's camera panes);
reach for it when you have a reason, not when a block would be tedious to write.

Contribution gating is purely **presence** — a block appears iff its straddle is staged;
there is no per-block `when:`. The schema lives in `$defs/settingsPanel`, `$defs/settingsRow`,
`$defs/settingsAction` and `$defs/settingsForm` of
`build-system/schemas/straddle.schema.json`.

Every settings surface in this workspace is described this way — enumerate them with
`grep -l '^settings:' <workspace>/*/straddle.yaml`, and read one before writing a new
one: spangap-net's WiFi block is the collection-with-candidates worked example, iface-tcp's
peers the smaller one, lxmf's the case where a fixed slot set is `when_key`-gated rows
rather than a collection. `storageSet` is **async** (it queues to the owning actor) — rely
on operation ordering, not an immediate read-back.

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
8. **Board straddles only — `detect_hw()`** in `esp-idf/src/detect.cpp`: the one
   place this board is detected. It returns its own `hw-<straddle>` string when
   the hardware under it is that board, NULL when it is not, and is written in the
   vocabulary of spangap-core's `detect_probe.h`. spangap-core declares the symbol
   **weak** and calls it from `serviceRunStart()` — before the first `onStart()`,
   which is the last moment no bus is claimed — comparing the answer with the board baked into the image; a mismatch logs an
   error and **halts the device awake** (the task parks on a slow loop with the
   RTC watchdog disabled, so the console stays up and the reason is re-stated
   rather than scrolling past), because every pin map in that image
   then belongs to someone else's board. Nothing else in the image references the
   function, so spangap-core keeps it on the link line with `-u detect_hw` — a
   weak undefined reference alone does not extract an archive member, and the
   symbol would resolve to null on a board that defines it perfectly well. A
   board build with no `detect_hw` warns on boot rather than passing silently. The confirmed answer is published as
   `sys.hw`, and announced on the console as `build: hw <board>` at boot and
   whenever one attaches — which is what lets a tool learn the board without
   asking, and without resetting the device to probe. Copy the same function into flashmon's detector (see
   `flashmon/docs/detect.md`); the copy is manual on purpose.

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

**Every doc opens with an executive summary.** Before the prose, before the
what-it-is paragraph: a fenced block that gives the whole thing as a
check → do ladder, in the order it actually happens.

```
condition?          no  → what happens instead, and stop
 ↓ yes
what is read/asked  → what it yields          (how often, if not once)
 ↓ loop/branch marked where it exists
the action
 ↓
how it is confirmed
```

Anything with a sequence — a protocol, a boot path, a state machine, a CLI
workflow, a build pipeline — reduces to one of these, and the reduction is the
point: a reader gets the shape in ten seconds and the body only has to explain
*why*. Prefer the real identifiers (`auth -O`, `state=ap`) over prose
paraphrase; keep it to a screen; put the two or three rules the ladder depends
on immediately under it. If a doc genuinely has no sequence (a key table, a
glossary), lead with the one-line invariant that governs the whole table
instead — but that is the rare case, not the default.

**Operator-guide shape** (a mono README or a `docs/<func>.md`): the executive
summary above, then one-paragraph what-it-is; brief origins (wraps/forks/ports what — detail goes to internals);
what it does and how it interacts with the other straddles, with one minimal
real usage example; the public surface (ports/API/opcodes, pointer to the header
for exact layouts); the **full storage-variable list** (settings with defaults,
runtime/telemetry, command sentinels, secrets — exhaustive, verified against
code); CLI / user manual. Never tell users to call an `xInit()` the generated
init already calls — state that it starts automatically when the straddle is in
the build.

**Maintainer shape** (an `INTERNALS.md` or `docs/<func>-internals.md`): the
executive summary (the ladder of what runs, in order, with the task each step
runs on), then §1 — an exhaustive inventory of everything changed/added relative
to the upstream/baseline; then task/threading model and ownership rules, wire/IPC
framing, lifecycle, and a dedicated pitfalls section. Self-authoritative.

Hard rules:

- **Lead with the executive summary.** Every doc, both roles. It is the first
  thing after the title, and it is a ladder, not a paragraph.

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
  `hw-lilygo-tdeck`) link siblings as `../../s/spangap/INTERNALS.md` or
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
