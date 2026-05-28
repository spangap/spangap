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

Pass `--no-web-ui` or `--no-lcd` at build time to exclude an activator.

### The build CLI

Most operations route through the in-container `spangap` CLI. The host-
side shim resolves the workspace (looking for `spangap.workspace.yaml`,
then walking up for `straddle.yaml`), starts the build-env container if
needed (`spangap-<hash7(workspace)>`), and execs in. Common verbs:

- `spangap build` / `spangap flash` / `spangap monitor`
- `spangap install <straddle>` — pull a straddle into the workspace
- `spangap clean` / `spangap reallyclean` — incremental vs source-only

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
