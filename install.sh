#!/bin/sh
# spangap installer. Fetches the single `spangap` launcher, checks host
# prerequisites, and drops it somewhere on your PATH.
#
#   curl -fsSL https://raw.githubusercontent.com/spangap/spangap/spangap/install.sh | sh
#
# Everything else spangap needs (the build container, the flash/monitor venv,
# straddle checkouts) is pulled in on demand by `spangap init` / `spangap build`
# — this only places the launcher. After that a workspace keeps the launcher
# current on its own (it auto-upgrades an out-of-date on-PATH copy), so this
# installer is a one-time convenience, not a moving part.
#
# The launcher is just one file, so the manual install is equally supported:
#   curl -o ~/bin/spangap <base>/spangap && chmod +x ~/bin/spangap
#
# Flags:
#   --bin-dir DIR   install into DIR (skips detection / prompting)
#   -y, --yes       accept defaults, never prompt (for piped / CI use)
#   -h, --help      this help
#
# Env:
#   SPANGAP_INSTALL_BASE   raw base URL to fetch from (default: the spangap
#                          branch on github). The launcher is <base>/spangap and
#                          its checksum <base>/spangap.sha256.
set -eu

BASE="${SPANGAP_INSTALL_BASE:-https://raw.githubusercontent.com/spangap/spangap/spangap}"
LAUNCHER_URL="$BASE/spangap"
SHA_URL="$BASE/spangap.sha256"

bin_dir=""
assume_yes=""

say()  { printf 'install: %s\n' "$*" >&2; }
die()  { printf 'install: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case $1 in
        --bin-dir) [ $# -ge 2 ] || die "--bin-dir needs a directory"; bin_dir=$2; shift 2 ;;
        --bin-dir=*) bin_dir=${1#*=}; shift ;;
        -y|--yes) assume_yes=1; shift ;;
        -h|--help) sed -n '2,30p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument '$1' (see --help)" ;;
    esac
done

# --- downloader -------------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL "$1"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -qO- "$1"; }
else
    die "need curl or wget to download the launcher"
fi

# --- prerequisites ----------------------------------------------------------
# Report the whole set of what's missing (with a remediation hint), not just the
# first, so the user can fix everything in one pass instead of one failed run
# per tool. python3 must also carry the venv module (Debian/Ubuntu split it out).
pkg_hint() {
    # $1: human name for the missing prerequisite.
    if command -v apt >/dev/null 2>&1 || command -v apt-get >/dev/null 2>&1; then
        case $1 in
            python3-venv) echo "  → sudo apt install python3-venv" ;;
            git)          echo "  → sudo apt install git" ;;
            docker)       echo "  → install Docker: https://docs.docker.com/engine/install/" ;;
        esac
    elif command -v apk >/dev/null 2>&1; then
        case $1 in
            python3-venv) echo "  → sudo apk add py3-virtualenv" ;;
            git)          echo "  → sudo apk add git" ;;
            docker)       echo "  → sudo apk add docker" ;;
        esac
    elif command -v brew >/dev/null 2>&1 || [ "$(uname -s)" = Darwin ]; then
        case $1 in
            python3-venv) echo "  → install python3 (venv ships with it): brew install python" ;;
            git)          echo "  → brew install git  (or install Xcode command line tools)" ;;
            docker)       echo "  → install Docker Desktop: https://www.docker.com/products/docker-desktop/" ;;
        esac
    else
        case $1 in
            python3-venv) echo "  → install python3 with its venv module" ;;
            git)          echo "  → install git" ;;
            docker)       echo "  → install docker" ;;
        esac
    fi
}

missing=""
command -v docker  >/dev/null 2>&1 || missing="$missing docker"
command -v git     >/dev/null 2>&1 || missing="$missing git"
if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import venv' >/dev/null 2>&1 || missing="$missing python3-venv"
else
    missing="$missing python3-venv"
fi

if [ -n "$missing" ]; then
    say "missing host prerequisites:"
    for m in $missing; do
        printf '  - %s\n' "$m" >&2
        pkg_hint "$m" >&2
    done
    say "install the above and re-run. (docker, git and python3+venv are all"
    say "needed before \`spangap init\` can bring up a workspace.)"
    exit 1
fi

# --- choose an install location ---------------------------------------------
# in_path DIR — is DIR a component of $PATH?
in_path() {
    case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac
}

target=""
existing=$(command -v spangap 2>/dev/null || true)

if [ -n "$bin_dir" ]; then
    mkdir -p "$bin_dir" || die "could not create $bin_dir"
    target="$bin_dir/spangap"
elif [ -n "$existing" ]; then
    # Upgrade in place at whatever path it already lives — respect the user's
    # earlier choice rather than second-guessing it.
    target="$existing"
    say "found an existing spangap at $target — updating it in place"
else
    # Prefer a per-user bin already on PATH; fall back to /usr/local/bin.
    default_dir=""
    for d in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin; do
        if [ -d "$d" ] && [ -w "$d" ] && in_path "$d"; then default_dir=$d; break; fi
    done
    # Nothing on PATH is writeable — pick the first writeable (or creatable) of
    # the per-user candidates and warn about PATH afterwards.
    if [ -z "$default_dir" ]; then
        for d in "$HOME/.local/bin" "$HOME/bin"; do
            if mkdir -p "$d" 2>/dev/null && [ -w "$d" ]; then default_dir=$d; break; fi
        done
    fi
    [ -n "$default_dir" ] || default_dir="$HOME/.local/bin"

    chosen=$default_dir
    # Prompt only when we can actually read a reply — a tty on /dev/tty (works
    # even when this script is piped from curl into sh) and not -y.
    if [ -z "$assume_yes" ] && [ -r /dev/tty ]; then
        printf 'install: directory to install the spangap launcher into [%s]: ' "$default_dir" >&2
        read -r reply </dev/tty || reply=""
        [ -n "$reply" ] && chosen=$reply
    fi
    # Expand a leading ~ manually (read doesn't).
    case $chosen in "~") chosen=$HOME ;; "~/"*) chosen="$HOME/${chosen#~/}" ;; esac
    mkdir -p "$chosen" || die "could not create $chosen"
    target="$chosen/spangap"
fi

target_dir=$(dirname "$target")
[ -w "$target_dir" ] || die "$target_dir is not writeable — re-run with --bin-dir DIR pointing at a writeable dir on your PATH, or with sudo"

# --- download + verify + place ----------------------------------------------
tmp=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/spangap.$$")
trap 'rm -f "$tmp" "$tmp.sha"' EXIT INT TERM HUP

say "downloading launcher from $LAUNCHER_URL"
fetch "$LAUNCHER_URL" > "$tmp" || die "download failed"
[ -s "$tmp" ] || die "downloaded launcher is empty"
head -1 "$tmp" | grep -q '^#!' || die "downloaded file doesn't look like the launcher (no shebang) — check SPANGAP_INSTALL_BASE"

# Checksum verify when both a published sum and a local sha256 tool are present.
# A missing sum file or tool is a soft skip (with a warning), not a hard fail —
# the launcher is a readable shell script, not an opaque binary.
if sums=$(fetch "$SHA_URL" 2>/dev/null) && [ -n "$sums" ]; then
    want=$(printf '%s\n' "$sums" | awk '{print $1; exit}')
    if command -v sha256sum >/dev/null 2>&1; then
        got=$(sha256sum "$tmp" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        got=$(shasum -a 256 "$tmp" | awk '{print $1}')
    else
        got=""
    fi
    if [ -z "$got" ]; then
        say "warning: no sha256 tool found — skipping checksum verification"
    elif [ "$want" = "$got" ]; then
        say "checksum verified"
    else
        die "checksum mismatch (expected $want, got $got) — refusing to install"
    fi
else
    say "warning: no published checksum at $SHA_URL — skipping verification"
fi

# Atomic-ish install: chmod the temp copy, then mv over the target.
chmod +x "$tmp"
mv "$tmp" "$target" || die "could not write $target"
trap - EXIT INT TERM HUP
rm -f "$tmp.sha" 2>/dev/null || true

say "installed spangap → $target"

if ! in_path "$target_dir"; then
    say "NOTE: $target_dir is not on your PATH. Add it, e.g.:"
    printf '    export PATH="%s:$PATH"\n' "$target_dir" >&2
    say "(put that line in your shell rc — ~/.bashrc, ~/.zshrc, …)"
fi

cat >&2 <<'EOF'
install: done. Next:
  spangap init <dir>        # create a workspace
  cd <dir>
  spangap build <org>/<repo> --with <org>/<board>
  spangap flash && spangap monitor
EOF
