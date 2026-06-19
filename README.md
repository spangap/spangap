# Spangap

This repository holds the **command line script, installer and build system** for [spangap](https://github.com/spangap) — the Device Application Framework for the ESP32, the on-device web-interface and more. See [https://github.com/spangap](https://github.com/spangap) for more general information on Spangap.

Spangap builds ESP32 device firmware using a host of software that never needs to touch your host system: it all runs in a docker container that is automatically set up as part of initializing a spangap 'workspace', a directory you build firmware in. All you need on the host is `docker`, `git`, `python3` and the `spangap` script this sits in the root of this repository. Apart the spangap command line shell script (installed in any directory in your `$PATH`) and a persistent home directory for the docker containers (in `~/.spangap`, nothing lives outside of the workspace(s) you initialize.)

Drop [`./spangap`](https://raw.githubusercontent.com/spangap/spangap/spangap) (the only file at the root of this repo) somewhere on your `$PATH` and make it executable. That's the entire install. Everything else — dependency resolution, the Docker image we use for building, the small Python venv we use for flashing and the serial monitor — it's all pulled in on demand.

## Host prerequisites

- **`docker`** — used for the build environment. Builds + runs in a per-workspace container; no toolchain on your host.
- **`git`** — clones the `spangap/` skeleton into your workspace on `spangap init`, and clones the named project plus its dependent straddles on `spangap build <org>/<repo>` (or `spangap get-deps`).
- **`python3`** with the `venv` module — on `spangap init`, used once to create `./.spangap-venv-<os>-<arch>/` inside the workspace and `pip install` pinned versions of [`esptool`](https://pypi.org/project/esptool/) and [`esp-idf-monitor`](https://pypi.org/project/esp-idf-monitor/) into it. These are what actually talk to the ESP-32 over the serial port for `spangap flash` and `spangap monitor`. The host suffix lets a workspace shared across hosts (e.g. a Linux VM and a Mac mounting it over the network) carry one venv per host without colliding. On Debian/Ubuntu you may need `apt install python3-venv` separately; on Alpine, `apk add py3-virtualenv`.

## Getting started

Spangap works for Linux, Mac and probably also Window (untested for now). Let's say you are in your homedir on a Mac and want to install the Reticulous mesh networking software built with Spangap and run it on the LilyGo T-Deck Plus device connected to port `/dev/cu.usbmodem1101` on your Mac. Let's say you want to install the spangap command line tool in ~/bin which is in your `$PATH` and you'd like the workspace directory to be called `tdeck` directly below your homedir.

```sh
curl -o ~/bin/spangap https://raw.githubusercontent.com/spangap/spangap/spangap)&& \
chmod a+x ~/bin/spangap && \
spangap init tdeck && \
cd tdeck && \
spangap monitor /dev/cu.usbmodem1101
```

Leave this running, it will show you the device log output and once we're done will allow you to switch to CLI mode by typing a command.

Now open a new terminal window and do:

```sh
cd tdeck && \
spangap build reticulous/reticulous --with reticulous/hw-tdeck && \
spangap flash
```

After downloading, building and flashing, the device now comes alive and presents a smartophone-like UI on the LCD as well as a full-featured web interface on a built-in access point named reticulous_<hex digits>. If you would rather have the device to meet you on your own wifi network, you can go the serial window and type `net add <ssid> <password>` (use quotes if your password has spaces.) To not leave the web UI unprotected, set a password using `passwd`.

## For more information

- [https://github.com/spangap](https://github.com/spangap) for more about spangap itself.
- [https://github.com/reticulous](https://github.com/reticulous) for more information about the Reticulous mesh networking firmware.
- [INTERNALS.md](INTERNALS.md) to learn what the Spangap build system actually does behind the scenes.
