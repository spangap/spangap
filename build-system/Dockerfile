# spangap build-env image.
#
# Holds:
#   - ESP-IDF v5.5.4 (from espressif/idf:v5.5.4, multi-arch incl. arm64)
#   - Node 20 + npm (Quasar/Vite browser build)
#   - cairo + Pillow + cairosvg + pypng + lz4 (LCD launcher-icon rasterizer)
#   - the in-container `spangap` CLI (Python)
#
# Built by spangap-outside with the spangap repo as context and this file as
# -f, i.e. COPY paths below are relative to the repo root.
#
# Tag: spangap-build-env:<ws_hash> (local, per-workspace — see spangap-outside).
# Eventual public tag is ghcr.io/spangap/build-env:<version> matching the
# platform-straddle version.
FROM espressif/idf:v5.5.4

# Node 20 via NodeSource (Ubuntu 22.04 ships Node 12, too old for Quasar/Vite).
# NodeSource publishes arm64 binaries.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*

# Cairo runtime + handy tools. python3-pip because the base image installs
# IDF's Python venv at /opt/esp/python_env but doesn't put pip3 on system PATH.
# iproute2 (`ip`) + netcat-openbsd (`nc`, supports -z/-v) + iputils-ping
# (`ping`) for diagnosing container→device network reach — the build container
# uses host networking (see spangap-outside ensure_container), so these are how
# you confirm it can actually hit a LAN device (ICMP) and its TCP CLI from
# inside.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libcairo2 \
        ccache \
        git \
        iproute2 \
        iputils-ping \
        jq \
        less \
        netcat-openbsd \
        sudo \
        vim-tiny \
        python3-pip; \
    rm -rf /var/lib/apt/lists/*

# Passwordless sudo for the `sudo` group. The base image's uid-1000 `ubuntu`
# user is already a member, so this grants it root-on-demand inside the
# container without a password. Keyed on the group (not the user) so it keeps
# working if the runtime user ever changes. Validated at build time; a syntax
# error in a sudoers file would otherwise lock sudo out entirely.
RUN set -eux; \
    echo '%sudo ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/nopasswd-sudo-group; \
    chmod 0440 /etc/sudoers.d/nopasswd-sudo-group; \
    visudo -cf /etc/sudoers.d/nopasswd-sudo-group

# Interactive bash prompt. Appended to /etc/bash.bashrc (not ~/.bashrc) because
# spangap-outside bind-mounts ~/.spangap over /home/spangap at runtime, which
# would shadow any HOME-level dotfile baked into the image. /etc/bash.bashrc is
# sourced by every interactive non-login bash (the `spangap shell` / `docker
# exec ... bash` path), and /etc is not mounted over. \w renders the cwd, \$
# becomes $ for spangap / # under sudo.
RUN { \
        echo ''; \
        echo '# spangap interactive prompt'; \
        echo "PS1='spangap:\\w \\\$ '"; \
        echo '# Route bare `claude` through `spangap claude` so the first-run setup'; \
        echo '# (permissions default + workspace CLAUDE.md seeding) always happens,'; \
        echo '# even when a user just opens a shell and types `claude`.'; \
        echo "alias claude='spangap claude'"; \
    } >> /etc/bash.bashrc

# Python deps. Two targets:
#   - System python3 (/usr/bin/python3): runs the in-container CLI; needs pyyaml+jsonschema.
#   - IDF Python venv (/opt/esp/python_env/idf5.5_py3.12_env): what `python3` resolves to
#     once `. $IDF_PATH/export.sh` activates the env. ESP-IDF CMake helpers call
#     `python3 lcd-icons.py` — that lands in the IDF venv, so Pillow/cairosvg/pypng/lz4
#     must be there for icon rasterization.
RUN pip3 install --no-cache-dir --break-system-packages pyyaml jsonschema
RUN /opt/esp/python_env/idf5.5_py3.12_env/bin/pip install --no-cache-dir \
        Pillow \
        cairosvg \
        pypng \
        lz4

# In-container CLI. spangap-inside lands at /usr/local/lib/spangap/cli.py.
# /usr/local/bin/spangap is a tiny bash wrapper that sources IDF's export.sh
# (so idf.py / the toolchain land on PATH) and then exec's the script.
# espressif/idf's entrypoint does the same but only fires once on `docker run`;
# every `docker exec` invocation has to re-establish the env itself.
RUN mkdir -p /usr/local/lib/spangap /usr/local/share/spangap
# Force modes on COPY so the in-image permissions don't depend on whatever the
# build context happens to expose. macOS SMB clients see host files as mode
# 0700 (no group/other); without --chmod that carries into the image and the
# `spangap` user can't read the script.
COPY --chmod=0755 build-system/spangap-inside /usr/local/lib/spangap/cli.py
COPY --chmod=0644 build-system/schemas/straddle.schema.json /usr/local/share/spangap/straddle.schema.json
# Container assistant instructions. Normally seeded into a workspace as README.md
# at `spangap init`; baked in here too so `spangap claude` can re-seed it (and the
# CLAUDE.md pointer it writes) in a workspace predating that flow. Version-matched
# to the CLI.
COPY --chmod=0644 build-system/README.md /usr/local/share/spangap/README.md

# Stamp the build-system/ content hash so spangap-outside can detect a stale
# cached image (build-system/ changed since the image was built) and rebuild.
ARG BUILDSYS_HASH=unknown
LABEL org.spangap.buildsys-hash=$BUILDSYS_HASH
RUN printf '%s\n' \
        '#!/usr/bin/env bash' \
        '# spangap — in-container entry. Sources IDF env (so subprocesses see' \
        '# idf.py on PATH and all the IDF env vars), then runs cli.py via the' \
        '# system /usr/bin/python3 — pip deps (pyyaml/jsonschema/cairo/PIL/etc)' \
        '# were installed there, NOT in the IDF venv that export.sh activates.' \
        'set -e' \
        'if ! command -v idf.py >/dev/null 2>&1; then' \
        '    . "$IDF_PATH/export.sh" >/dev/null 2>&1' \
        'fi' \
        'exec /usr/bin/python3 /usr/local/lib/spangap/cli.py "$@"' \
        > /usr/local/bin/spangap && \
    chmod +x /usr/local/bin/spangap

# Rename the base image's uid-1000 `ubuntu` user (and its group + home dir) to
# `spangap`. UID/GID stay 1000, so files written to the bind-mounted workspace
# still land as the conventional host user, not root — only the names change.
# Group memberships (including `sudo`) survive usermod, so passwordless sudo
# keeps working. usermod -m moves /home/ubuntu → /home/spangap.
RUN set -eux; \
    usermod -l spangap -d /home/spangap -m ubuntu; \
    if getent group ubuntu >/dev/null; then groupmod -n spangap ubuntu; fi

# Run as that uid-1000 `spangap` user. Matching UID/GID with the conventional
# host user means files written to the bind-mounted workspace land as the host
# user, not root.
USER spangap
ENV HOME=/home/spangap

# User-owned npm prefix so `npm install -g` works without sudo. `spangap
# claude` lazy-installs @anthropic-ai/claude-code into this prefix on first
# use. Set via env (not `npm config set prefix`, which would write
# ~/.npmrc — that lives at /home/spangap/.npmrc and gets hidden the moment
# spangap-outside bind-mounts ~/.spangap over /home/spangap). ensure_container
# creates the prefix dir post-run since the image layer's mkdir is also
# shadowed.
ENV NPM_CONFIG_PREFIX=/home/spangap/.npm-global
ENV PATH=/home/spangap/.npm-global/bin:$PATH

# The workspace bind-mount lands at /home/spangap/<basename> (under the
# persistent ~ mount), not a fixed path; straddles are container-native dirs at
# <workspace>/<repo>. spangap-outside passes
# --workdir (and SPANGAP_WORKSPACE) to every `docker exec`, so this WORKDIR is
# mostly cosmetic (default for `docker run` only, and the container is started
# with `sleep infinity`). Set to the home mount, which is always present.
WORKDIR /home/spangap

# Default to bash so `spangap shell` lands the user in something familiar.
CMD ["bash"]
