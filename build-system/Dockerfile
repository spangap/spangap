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
# Tag: spangap-build-env:dev (local). Eventual public tag is
# ghcr.io/spangap/build-env:<version> matching the platform-straddle version.
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
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libcairo2 \
        ccache \
        git \
        jq \
        less \
        vim-tiny \
        python3-pip; \
    rm -rf /var/lib/apt/lists/*

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
# `ubuntu` user can't read the script.
COPY --chmod=0755 build-system/spangap-inside /usr/local/lib/spangap/cli.py
COPY --chmod=0644 build-system/schemas/straddle.schema.json /usr/local/share/spangap/straddle.schema.json

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

# Run as the base image's UID-1000 `ubuntu` user. Matching UID/GID with the
# conventional host user means files written to the bind-mounted workspace
# land as the host user, not root.
USER ubuntu
ENV HOME=/home/ubuntu

# User-owned npm prefix so `npm install -g` works without sudo. `spangap
# claude` lazy-installs @anthropic-ai/claude-code into this prefix on first
# use (the npm cache volume keeps reinstall fast across container rebuilds).
RUN mkdir -p /home/ubuntu/.npm-global && \
    npm config set prefix /home/ubuntu/.npm-global
ENV PATH=/home/ubuntu/.npm-global/bin:$PATH

# Workspace bind-mount lands here. spangap-outside does `docker run -d -v <ws>:/work`.
WORKDIR /work

# Default to bash so `spangap shell` lands the user in something familiar.
CMD ["bash"]
