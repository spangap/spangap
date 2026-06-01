# spangap

This repo is the **installer and build system** for [spangap](https://github.com/spangap) — the Device Application Framework for the ESP32 _and_ the on-device web-interface. For what spangap *is*, what it solves, and the shape of the rest of the straddles, see the org-level README at [https://github.com/spangap](https://github.com/spangap).

## All you need is `docker`, `git`, `python3` and the `spangap` script

Drop [`./spangap`](https://raw.githubusercontent.com/spangap/spangap/spangap) (the only file at the root of this repo) somewhere on your `$PATH` (e.g. `~/.local/bin/spangap`) and make it executable. That's the entire install. Everything else — dependency resolution, the Docker image we use for building, the small Python venv we use for flashing and the serial monitor — it's all pulled in on demand by the script, and apart from that simple script in your `$PATH`, it all lives in the directory you work in, and nowhere else.

### Host prerequisites

- **`docker`** — used for the build environment. Builds + runs in a per-workspace container; no toolchain on your host.
- **`git`** — clones the `spangap/` skeleton into your workspace on `spangap init`, and fetches dependent straddles on `spangap build` / `spangap get-deps`.
- **`python3`** with the `venv` module — on `spangap init`, used once to create `./.spangap-venv-<os>-<arch>/` inside the workspace and `pip install` pinned versions of [`esptool`](https://pypi.org/project/esptool/) and [`esp-idf-monitor`](https://pypi.org/project/esp-idf-monitor/) into it. These are what actually talk to the ESP-32 over the serial port for `spangap flash` and `spangap monitor`. The host suffix lets a workspace shared across hosts (e.g. a Linux VM and a Mac mounting it over the network) carry one venv per host without colliding. On Debian/Ubuntu you may need `apt install python3-venv` separately; on Alpine, `apk add py3-virtualenv`.

Nothing else — no native ESP-IDF install on the host.

Say you wanted to install 'Reticulous`, mesh networking software built with spangap for the LilyGo T-Deck Plus device. All you would do after you copied the script to your $PATH is:

```sh
mkdir tdeck && \
cd tdeck && \
spangap init reticulous/hw-tdeck && \
spangap build && \
spangap flash <serial port>
```

`spangap init` sets up the workspace, clones this repo into `./spangap/`, and creates `./.spangap-venv-<os>-<arch>/` with the host-side flash/monitor tooling. Pass an optional `<org>/<repo>` (or full `https://…` URL) and it also clones that project as a workspace sibling. From then on, `spangap` passes on commands it doesn't know about to scripts outside and then inside a Docker container it will create when it starts building software — and from the workspace root, single-straddle commands like `build` / `flash` / `monitor` find the project automatically, so you don't need to `cd` into it.

## Read next

- [https://github.com/spangap](https://github.com/spangap) for more about spangap itself.
- [INTERNALS.md](INTERNALS.md) — what the build system actually does, dispatcher layout, container conventions, gotchas.
