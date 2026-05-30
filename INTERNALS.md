# spangap — internals

Platform-wide architecture, conventions, and gotchas. Each individual
straddle has its own `INTERNALS.md` for the code it ships; this file is
for the cross-cutting things every straddle assumes.

## The straddles model

A **straddle** is a unit of dual-side functionality: a `straddle.yaml`
manifest at the root, optionally an `esp-idf/` subdir for the firmware
half, optionally a `browser/` subdir for the browser half, optionally an
`esp-idf/lcd/` slice for on-device LVGL UI. Each straddle declares its
dependencies (other straddles, by `<namespace>/<name>`), and the
build CLI stages everything into ESP-IDF's component graph at build
time.

Two manifest keys carry deps:

- **`requires:`** — hard. Missing one is a build error; can't be excluded.
- **`optional_requires:`** — soft, **default-on**. Pruned silently when
  the dep isn't in the staged set (not cloned, not in the buildable's
  requires, or dropped by `--exclude` / `--no-X`).

There's no manifest list of "extras you might also want" — anything the
user wants beyond the curated set goes in via `--include <name>` at build
time (see "Common verbs" below for the slash-vs-bare semantics).

Source code gates corresponding call sites on the auto-generated
`CONFIG_STRADDLE_<UPPER_REPO>` symbol (so absence compiles away cleanly).
The following central straddles also get short-form aliases that source
code prefers as a stable spelling: `CONFIG_SPANGAP_LCD`,
`CONFIG_SPANGAP_WEB`, `CONFIG_SPANGAP_OTA`, `CONFIG_SPANGAP_WG`,
`CONFIG_SPANGAP_UPNP`, `CONFIG_SPANGAP_DUCKDNS`, `CONFIG_SPANGAP_ACME`.

```
<straddle>/
├── straddle.yaml         schema_version, name, prefix, version, firmware, browser, requires
├── esp-idf/              firmware half (an IDF managed component)
│   ├── idf_component.yml
│   ├── CMakeLists.txt
│   ├── include/          public headers
│   ├── src/              implementation + private headers
│   └── lcd/              optional: on-device UI slice, folded in by spangap-lcd
└── browser/              browser half (TS/Vue, consumed as source)
    ├── package.json
    └── src/
```

`prefix` is the symbol prefix the straddle uses (`net`, `lxmf`, …); the
empty prefix is reserved for `spangap-core` so its symbols read as
language primitives (`storageGet`, `cliRegister`, `info`, …).

### Activator straddles

Two straddles act as **UI activators** that fold the right slice from
every other straddle into a single build product:

- **`spangap-web`** picks up every other straddle's `browser/` subdir and
  generates the browser-side dispatcher.
- **`spangap-lcd`** picks up every other straddle's `esp-idf/lcd/` slice,
  folds it into that straddle's firmware component, and calls
  `<prefix>LcdInit()` from a generated dispatcher.

Pass `--no-web` or `--no-lcd` at build time to exclude an activator.

### How staging and gating fit together

`spangap-inside` resolves the buildable's `requires:` ∪ `optional_requires:`
∪ (any straddles named via `--include`) transitively, subtracting any
`--exclude` / `--no-X` entries, then stages each kept dep into
`staging/components/<repo>/` as a real dir containing per-entry symlinks to
the source dir's contents plus two generated files:

- **`spangap_requires.cmake`** — `set(SPANGAP_REQUIRES …)` with this
  dep's effective cross-straddle REQUIRES (hard requires plus
  optional_requires intersected with staged). Each consumer
  CMakeLists.txt does:

  ```cmake
  include(${CMAKE_CURRENT_LIST_DIR}/spangap_requires.cmake)
  idf_component_register(
      ...
      REQUIRES ${SPANGAP_REQUIRES} <IDF/managed deps>
  )
  ```

  The buildable's `main/CMakeLists.txt` reads its own generated file at
  `${CMAKE_CURRENT_LIST_DIR}/../staging/main_requires.cmake`. (Note:
  `CMAKE_CURRENT_LIST_DIR`, not `CMAKE_SOURCE_DIR` — in IDF's component-
  requirements pre-pass the latter resolves to the build dir, breaking
  the include.)

- One sibling staged component, **`_spangap_present`**, contains an
  auto-generated `Kconfig.projbuild` declaring one hidden
  `config STRADDLE_<UPPER_REPO>` (bool, default y) per staged straddle,
  plus a short-form alias for each well-known central straddle when staged
  (`SPANGAP_LCD`, `SPANGAP_WEB`, `SPANGAP_OTA`, `SPANGAP_WG`, `SPANGAP_UPNP`,
  `SPANGAP_DUCKDNS`, `SPANGAP_ACME`). IDF picks `Kconfig.projbuild` up
  automatically from any component, so the corresponding `CONFIG_*` symbols
  are visible to every source file and every CMakeLists `if(CONFIG_*)`.

- A separate generated file, **`staging/sdkconfig.spangap-overrides`**, is
  the highest-priority entry in `SDKCONFIG_DEFAULTS`. spangap-inside writes
  CLI-driven Kconfig values into it (today: `--flash-size`; eventually also
  things like `--chip-target`). The bootstrap.cmake staleness check picks
  up content changes and regenerates sdkconfig so the new value takes
  effect on the next configure.

- Partition table: `bootstrap.cmake` calls `gen-partitions.py` with the
  flash size from `CONFIG_ESPTOOLPY_FLASHSIZE_*MB`, the app-share percent
  from `CONFIG_SPANGAP_APP_PERCENT`, and OTA on/off **derived from whether
  `staging/components/ota/` exists** (not a Kconfig knob — staged set is
  authoritative). OTA on → paired A/B app + fixed; OTA off → single,
  bigger app + fixed.

A staging-time **lint** rejects any `idf_component_register(REQUIRES …)`
that hand-writes a known straddle repo name. Cross-straddle deps must
flow through `${SPANGAP_REQUIRES}` — otherwise `--no-X` can't narrow
them, and the gate falls out of sync with the staged set.

### The build CLI

The host-side entry script is `./spangap` at the platform-repo root. It
walks up from cwd for `spangap.workspace.yaml` (only — there's no
straddle-as-workspace fallback) and dispatches into
`<ws>/spangap/build-system/spangap-outside`, which in turn either handles
the command on the host (flash, monitor, cli, get-deps, reset) or
docker-execs `spangap-inside` in the build-env container
(`spangap-<hash7(workspace)>`).

**Workspace layout.** No symlinks. Straddles reach the container through one
of two flat, container-native roots:

- `/repos/<repo>` — the **flat** local checkout (`<repo_path>/<repo>`, every
  straddle a direct child) passed to `init --repo-path`, bind-mounted *whole*
  to `/repos` (one mount). Adding/removing a straddle under it needs no
  `spangap reset` — the whole-tree mount picks it up live. **repo_path mode is
  local-only and never clones:** the checkout is a pinned set you always build
  against, so a required straddle that isn't in it is an error (add it to the
  checkout), never a silent github fetch of a possibly-different copy. Build a
  workspace from scratch against it and nothing comes from github.
- `/workspace/<repo>` — git clones, used **only without `--repo-path`**: the
  host fetches missing transitive deps here, and they stay (pinned) until you
  delete them. The workspace dir also holds the marker, the dotfiles, and the
  per-host venv.

`spangap-inside` scans both roots. Because each root is flat, the browser
`file:../../<sibling>/browser` deps — which assume straddle roots are flat
siblings — resolve directly; there's no synthetic re-mount. (An earlier
design used a separate `/work` mount plus a `.link` symlink suffix to paper
over an *org-layered* checkout, where those `file:` deps dangled; flattening
the checkout removed the need for both.) The container sees three mounts:
`/workspace`, `/repos`, and the persistent `/home/ubuntu`.

**No host paths inside.** Because straddles are referenced at their container
paths (`/repos/<repo>`, `/workspace/<repo>`) and never via a host-absolute
symlink, the `CMAKE_HOME_DIRECTORY` baked into `build/CMakeCache.txt` is a
container path — stable and host-independent. (Flash/monitor on the host read
`build/` through the same inode: `/repos` *is* `<repo_path>` on the host.)

**Project resolution is symmetric across the two sides.** From the workspace
root, both `spangap-outside` (`require_straddle`) and `spangap-inside`
(`find_project`) fall back to the `.spangap-project` default, so `build` /
`flash` / `validate` work from the root — on the host and inside the
container — not only from inside the straddle dir. (Targeting a *non-default*
straddle by `cd`-ing into it isn't supported under repo_path, since those
straddles live at `/repos`, outside the workspace tree on the host; that's a
future `spangap build <straddle>` argument.)

**No-workspace fallback** — `spangap monitor <dev>` and `spangap cli`
also run with no `spangap.workspace.yaml` at/above cwd. The entry script
resolves its own real path (chasing symlinks through `/usr/local/bin/…`)
to find `build-system/spangap-outside`, sets `SPANGAP_WORKSPACE=$HOME`
so the venv + sticky `.spangap-port-<os>-<arch>`/`.spangap-host` files land there,
and `spangap-outside`'s `monitor` warns *"not in spangap workspace,
cannot decode stack on crash, cannot be signalled to flash"* and runs
without an elf or a flashme watcher. Everything else still requires
`spangap init`.

Common verbs:

- `spangap build [flags]` — staged-set + build-config knobs per build:
  - `-v` / `--verbose` shows the full IDF / Vite output. **Quiet by
    default** — only real compiler/build-tool diagnostics (plus a few
    lines of trailing context) are kept, and the flash banner is rewritten
    to `spangap flash <port>`. This filtering lives in `spangap-inside`, so
    it applies the same whether you reach the build through the host
    `spangap build`, `spangap docker spangap build`, or a shell inside the
    container; `spangap-outside` just forwards the flag (and the host's
    sticky port via `$SPANGAP_PORT`).
  - `--exclude <name>` (repeatable) drops an `optional_requires:` entry.
    Bare repo (`spangap-lcd`) or fully-qualified (`spangap/spangap-lcd`).
    Excluding a hard `requires:` target is an error. `--no-lcd` /
    `--no-web` are aliases.
  - `--include <name>` (repeatable) pulls an extra straddle into this
    build. Bare repo (`spangap-sshd`) must already be a workspace
    sibling. Fully-qualified `<org>/<repo>` (`spangap/spangap-sshd`) is
    auto-cloned from github by the host dispatcher if not yet present.
    The included straddle is treated as a soft dep root: its own
    `requires:` / `optional_requires:` are followed transitively.
  - `--flash-size <MB>` overrides `CONFIG_ESPTOOLPY_FLASHSIZE_*MB` for
    this build — useful when running a generic spangap firmware against
    differently-sized hardware. Valid: 4, 8, 16, 32, 64, 128. Probe a
    connected chip's actual flash size with `spangap probe <dev>` (a thin
    wrapper around `esptool.py flash_id` that also prints the matching
    `--flash-size` invocation).
- `spangap flash <dev>` / `spangap monitor <dev>`
- `spangap get-deps` — host-side `git clone` of any missing transitive
  `requires:` (also runs implicitly as the first phase of `build`)
- `spangap cli [-h <host>] <cmd>…` — talk to the device's TCP CLI
- `spangap clean` / `spangap reallyclean` — incremental vs source-only
- `spangap docker <cmd>…` — raw `docker exec` into the build-env container
  (e.g. `spangap docker sh` to drop into a shell, `spangap docker claude`)

Local sibling-checkout development uses the `--spangap` flag (or its
moral equivalent in this CLI) so a build resolves `spangap-core` from
`../spangap-core` instead of the registry; the committed
`idf_component.yml` stays registry-shaped.

## ITS — inter-task streaming

`its.h`/`its.cpp` is the single communication layer. Treat it as **TCP
between FreeRTOS tasks**.

- **Server**: `itsServerInit(maxHandles, toSize, fromSize)`. Pre-allocates
  stream buffers per handle in PSRAM.
- **Client**: `itsClientInit(maxConns, onDisconnect)`.
- **Connect**: `itsConnect("taskName", itsPort, data, len, timeout, ref)`
  → server's `onConnect(handle, itsPort, data, len)` returns serverRef
  (≥ 0 = accept, < 0 = reject).
- **itsPort**: 16-bit endpoint identifier flowing from connect →
  onConnect so the server knows which registered endpoint (TCP port,
  URL path, DC label) the connection is for.
- **Forward**: `itsServerForward(handle, "targetTask", itsPort, data,
  len)` — transfer a server handle to another server task without
  copying. The middle task is fully out of the data path.
- **Inject**: `itsServerInject(handle, data, len)` — write data into a
  server handle's receive buffer (used before forward to put consumed
  HTTP headers back).
- **Stream**: `itsSend(handle, data, len, timeout)` /
  `itsRecv(handle, buf, maxLen, timeout)`.
- **Aux messages**: `itsSendAux("taskName", data, len, timeout, port)`
  for task-to-task signalling that isn't a connection (subscribe/notify,
  register-with-net handshake).
- **Inbox**: FreeRTOS Queue (thread-safe, multi-producer).
  `itsPoll(timeout)` reads one message, dispatches to callback.

**ITS is no longer ISR-safe** (the inbox queues are now PSRAM-backed via
`xQueueCreateWithCaps(MALLOC_CAP_SPIRAM)`, which reclaims ~40 KB DRAM
platform-wide). ISRs should set a heap flag plus `vTaskNotifyGiveFromISR`,
picked up by the target task's `itsPoll`.

Deep dive: [spangap-core/docs/its.md](../spangap-core/docs/its.md).

## Storage — the config tree

In-memory cJSON tree, synced device↔browser over one `storage:1`
DataChannel. Prefix conventions:

- `s.*` — persisted to flash **and** synced to the browser.
- `secrets.*` — persisted **but never** sent to the browser.
- no prefix — ephemeral, lost on reboot, mirrored to the browser while
  alive.

`storageDefault*` writes are **silent** — they don't fire change
subscriptions. Use `storageSet` when subscribers need to react.

```cpp
#define MYMOD_VERSION 2  // bump when adding new keys
if (storageGetInt("s.mymod.version", 0) < MYMOD_VERSION) {
    storageDefault("s.mymod.new_key", default_value);
    storageDefaultTree("s.mymod", "{\"key\":42}");
    storageSet("s.mymod.version", MYMOD_VERSION);
}
```

The state store can live on **SD**. If `/sdcard/state` exists at boot it
becomes the active store; `/state` stays mounted but unused. Code never
hard-codes `/state` — it uses `fsStateDir()` / `fsStatePath()` (see
[storage.md](../spangap-core/docs/storage.md)). The config file is
`<stateDir>/storage/root.json`. The on-flash partition is `/state`;
externals live under `storage/external/<prefix>.json`.

`reset factory` is refused when booted from SD. CLI commands:
`format flash`, `format sd`.

## Common recipes

### Add a CLI command

```cpp
cliRegisterCmd("mycmd", [](int argc, char** argv) {
    if (argc > 1 && strcmp(argv[1], "sub") == 0) { info("mycmd sub\n"); return; }
    info("usage: mycmd sub\n");
});
```

CLI commands are **silent on success** (`set`, `unset`, `save`, `detect`
produce no output on success).

### Add an ITS server port

```cpp
itsServerInit();
itsServerPortOpen(MY_PORT, MAX_CLIENTS, toBufSize, fromBufSize);
itsServerOnConnect(MY_PORT, onConnect);
itsServerOnRecv(MY_PORT, onRecv);
itsServerOnDisconnect(MY_PORT, onDisconnect);

// Register with net for TCP port, or with web for URL prefix:
net_port_msg_t reg = { .port = MY_PORT, .taskName = "mytask" };
itsSendAux("net", NET_PORT_REG_PORT, &reg, sizeof(reg), pdMS_TO_TICKS(500));
// or
web_path_msg_t wreg = { .itsPort = MY_PORT };
safeStrncpy(wreg.path, "mypath", sizeof(wreg.path));
itsSendAux("web", WEB_PATH_REG_PORT, &wreg, sizeof(wreg), pdMS_TO_TICKS(500));
```

### Add a browser DataChannel (WebRTC)

**Device**: open a packet-mode ITS server port. The webrtc task auto-
routes DC labels to ITS ports.

```cpp
itsServerPortOpen(MY_DC_PORT, 1, 2048, 4096);
itsServerOnConnect(MY_DC_PORT, onDcConnect);
itsServerOnRecv(MY_DC_PORT, onDcRecv);
// Browser creates DC with label "mytask:1" → webrtc-task parses port → itsConnect here.
```

**Browser**: register a channel builder with the spangap session.

```typescript
webrtcSession.registerChannel((pc) => {
  const dc = pc.createDataChannel('mytask:1', { ordered: true, protocol: JSON.stringify({...}) });
  dc.onmessage = (e) => { /* ... */ };
  return dc;
});
```

### Add a UI settings panel

1. Create `web-interface/src/modules/panels/MyPanel.vue` in the
   consuming app (or in the straddle's own `browser/src/panels/`).
2. Register: `menuRegistry.register({ group: 'My Group', id: 'my-panel',
   label: 'My Panel', component: () => import('./panels/MyPanel.vue') })`.
3. Use spangap's `SettingToggle` / `SettingSlider` / `SettingSelect` /
   `SettingText` components for config-bound controls.
4. For the on-device equivalent (`CONFIG_SPANGAP_LCD` builds), register
   a pane with `lcdRegisterSettings("Group/Item", "Item", fn)` and build
   it with the `lcdSetting*` helpers — gate the call behind
   `#if CONFIG_SPANGAP_LCD`.

### Add a cron entry from a module

```cpp
cronDefault("*/15 *    *    *    *    N    mycmd sub", "mycmd sub");
// Flags: - = always, A = awake only, N = STA upstream only.
```

### Add a net event callback

```cpp
netRegister(NET_EV_UPSTREAM_UP, [](const char* data) { info("upstream up\n"); });
// Events: NET_EV_UP, NET_EV_DOWN, NET_EV_UPSTREAM_UP, NET_EV_UPSTREAM_DOWN, NET_EV_CFG_CHANGED, NET_EV_POLL
```

`netRegister()` **level-replays UP edges**: a handler registered for
`NET_EV_UP` / `NET_EV_UPSTREAM_UP` *after* the link is already up is
invoked immediately. UP handlers must therefore be idempotent and must
tolerate running on the registering task, not just the net task. DOWN /
CFG / POLL remain edge-only.

## Coding conventions

- Use `info()` / `warn()` / `err()` / `dbg()` / `verb()` — not
  `ESP_LOGx` directly. The log task prepends `[taskname]` automatically;
  code on unregistered tasks must prefix manually.
- Use `safeStrncpy(dst, src, n)` not `strncpy` — always NUL-terminates,
  logs on truncation.
- Prefer modern C++ (`std::string`, `std::string_view`). Avoid C-style
  `char[]`/`strstr` parsing.
- Xtensa `uint32_t` is `long unsigned int` — cast with `(unsigned)` for
  `%u` in printf.
- The canonical `itsPoll` loop:
  `for (;;) { while (itsPoll(0)) {}; /* non-ITS work */; itsPoll(blockTime); }`
- Do **not** include the task name in log messages — `[taskname]` is
  prepended automatically.
- **No PlatformIO** — ESP-IDF only.

## Gotchas

- **PSRAM-stack tasks can't do FS-layer flash I/O.** Route all file
  I/O through `fs.cpp` workers.
- **`itsPoll` with short timeout in `while()` → infinite spin.** Use
  `itsPoll(timeout); while (itsPoll(0)) {}` only when you genuinely need
  a periodic backstop.
- **`vTaskDelay(1)` is mandatory in webrtc_task's main loop** — without
  it the IDLE0 watchdog fires on core 0.
- **Never `printf` from PSRAM-stack tasks** — use `info()`.
- **lwIP `O_NONBLOCK` / `MSG_DONTWAIT` can still briefly block.** Use
  `select()` with zero timeout before `accept()` / `recv()`.
- **ESP-IDF 5.x `netif->state` conflict with WireGuard** — required
  workaround: `CONFIG_LWIP_PPP_SUPPORT=y`.
- **`CONFIG_ESP_WIFI_NVS_ENABLED=n`** — prevents the WiFi blob from
  auto-reconnecting outside `net.cpp` and avoids mid-session NVS writes.
- **SDMMC DMA requires internal DRAM buffers** — the fs worker
  serializes all SD access.
- **ESP32-S3 AES-GCM hardware DMA bug** (espressif/esp-idf#12689) —
  spangap uses ChaCha20-Poly1305 for TLS/DTLS.
- **IDF 5.5 `HEAP_TASK_TRACKING` global mutex** —
  `spangap-core/src/heap_track_stub.c` provides `--wrap` no-op stubs;
  required for stable cJSON-heavy workloads.

## ESP-IDF specifics

- **PSRAM malloc**: `CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL=0` — `malloc()`
  prefers PSRAM. DMA/WiFi/lwIP use `MALLOC_CAP_INTERNAL` /
  `MALLOC_CAP_DMA` explicitly. `CONFIG_SPIRAM_MALLOC_RESERVE_INTERNAL=32768`
  reserves the DRAM pool.
- **Console**: USB Serial JTAG (`CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=y`);
  light sleep kills it.
- **Task watchdog**: IDLE1 not monitored
  (`CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU1=n`) — core 1 hosts heavy
  workers.
- **TCP buffers**: `SO_SNDBUF` setsockopt is silently ignored —
  `TCP_SND_BUF` is compile-time only. Set
  `CONFIG_LWIP_TCP_SND_BUF_DEFAULT=16384`. TCP streaming requires
  `TCP_NODELAY`.

## Partition layout (default; apps may override)

- `nvs` (20 KB @ 0x9000) — IDF internal use only (WiFi cal, PHY data).
  App code never reads/writes NVS.
- `app0` (~6.25 MB @ 0x10000) — firmware.
- `fixed` (~1.44 MB @ 0x670000, **read-only**) — LittleFS, flashed every
  build, mounted at `/fixed`. Contains `webroot/`, `factory_state/`
  (boot, crontab, net_up, `storage/external/<prefix>.json` blobs), and
  `additional_state/` (first-boot overlay).
- `state` (128 KB @ 0x7E0000) — LittleFS, read-write, mounted at
  `/state` **always**. Contains `boot`, `net_up`, `crontab`, TLS certs,
  ACME key, and `storage/`. Auto-formatted on first boot; `reset factory`
  / `format flash` formats it and copies from `/fixed/factory_state/`.

## Hardware

ESP32-S3 family, dual-core, 8 MB PSRAM (OPI), 8 MB flash (typical), WiFi.
No other Espressif chips are currently targeted.

## Subsystem deep dives

The detail of each subsystem lives in `docs/` *in the straddle that owns
it*. Cross-cutting docs that still live in `spangap-core`:

- [docs/its.md](../spangap-core/docs/its.md) — ITS architecture
- [docs/storage.md](../spangap-core/docs/storage.md)
- [docs/unified-fs-api.md](../spangap-core/docs/unified-fs-api.md)
- [docs/cron.md](../spangap-core/docs/cron.md)
- [docs/power-management.md](../spangap-core/docs/power-management.md)
- [docs/logging.md](../spangap-core/docs/logging.md)
- [docs/getting-started.md](../spangap-core/docs/getting-started.md)
- [docs/development.md](../spangap-core/docs/development.md)
- [docs/key-fixes.md](../spangap-core/docs/key-fixes.md) — hard-won bug
  fixes by subsystem
- [docs/idf-tweaks.md](../spangap-core/docs/idf-tweaks.md) — local IDF
  workarounds

Subsystem-specific docs (web, auth, tls, ntp, ota, webrtc, lcd, …)
move with the straddle that owns the code.
