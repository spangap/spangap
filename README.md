# Spangap — command-line tool & build system

This repository is just one component of [**Spangap**](https://github.com/spangap), the Device Application Framework for the ESP32. It holds the **command-line launcher, the installer, and the build system** — the tooling you use to assemble and flash firmware. It is not the platform itself; for what Spangap is and what it can do, read the **[org README](https://github.com/spangap)**.

## What this repo provides

Spangap builds ESP32 firmware inside a Docker container that is set up automatically when you initialize a *workspace* (a directory you build firmware in). Nothing but the container's own home lands outside your workspaces — it lives in `~/.spangap` — and on the host you only need `docker`, `git`, `python3`, and the single-file `spangap` launcher this repo ships.

The launcher stays a thin dispatcher; the real build system lives in the per-workspace `spangap/` skeleton that `spangap init` sets up. Because of that, a workspace keeps your launcher current on its own: when it ships a newer launcher than the one on your `$PATH`, it upgrades that file in place (printing `spangap: auto-upgraded <path>`), or tells you a newer one is available if the file isn't writeable. So you rarely need to re-install.

## Install

One-liner — checks your prerequisites, finds (or asks for) a directory on your `$PATH`, and drops the launcher there:

```sh
curl -fsSL https://raw.githubusercontent.com/spangap/spangap/refs/heads/main/install.sh | sh
```

Or do it by hand — the launcher is a single file. Drop [`./spangap`](https://raw.githubusercontent.com/spangap/spangap/refs/heads/main/spangap) (the only file at the root of this repo) somewhere on your `$PATH` and make it executable. Either way that's the entire install: dependency resolution, the Docker build image, and the small Python venv used for flashing and the serial monitor are all pulled in on demand.

## Host prerequisites

- **`docker`** — the build environment. Builds and runs in a per-workspace container; no toolchain on your host.
- **`git`** — clones the `spangap/` skeleton on `spangap init`, and the named project plus its dependent straddles on `spangap build <org>/<repo>` (or `spangap get-deps`).
- **`python3`** with the `venv` module — on `spangap init`, creates `./.spangap-venv-<os>-<arch>/` in the workspace and `pip install`s pinned [`esptool`](https://pypi.org/project/esptool/) and [`esp-idf-monitor`](https://pypi.org/project/esp-idf-monitor/) into it. These are what actually talk to the ESP32 over the serial port for `spangap flash` and `spangap monitor`. The host suffix lets a workspace shared across hosts (e.g. a Linux VM and a Mac mounting it over the network) carry one venv per host without colliding. On Debian/Ubuntu you may need `apt install python3-venv` separately; on Alpine, `apk add py3-virtualenv`.

## Using it

Initialize a workspace, start a serial monitor, then build a project *with* a board and flash it. For example, to build the Reticulous mesh firmware for a LilyGo T-Deck Plus on `/dev/cu.usbmodem1101`:

```sh
spangap init tdeck && cd tdeck
spangap monitor /dev/cu.usbmodem1101      # leave running: shows the device log, and flashes on request
```

Then, in another terminal:

```sh
cd tdeck
spangap build reticulous/reticulous --with spangap/hw-lilygo-tdeck
spangap flash
```

`spangap build <org>/<repo>` clones the project and its dependencies on first use; `--with <board>` supplies the hardware HAL. `spangap flash` signals the running monitor to write the image. Run bare `spangap` at any point to see the resolved project, its dependencies, and the environment report.

## For more information

- [https://github.com/spangap](https://github.com/spangap) — what Spangap is, and the platform straddles it provides.
- [https://github.com/reticulous](https://github.com/reticulous) — the Reticulous mesh firmware used as the example above.
- [INTERNALS.md](INTERNALS.md) — what the Spangap build system actually does behind the scenes.
