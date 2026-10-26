#!/usr/bin/env bash
# Fungsi bersama untuk script boutique-experiments.

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export PATH="$PATH:$HOME/cloud2023/kubernetes/bin:$ROOT/.venv/bin"

# load_env FILE: export KEY=VALUE dari FILE, kecuali KEY sudah di-set oleh pemanggil.
# Nilai boleh memakai ${VAR} yang sudah terdefinisi sebelumnya.
load_env() {
    local line key
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        key=${line%%=*}
        if [ -z "${!key+x}" ]; then
            eval "export $line"
        fi
    done < "$1"
}

need() {
    command -v "$1" >/dev/null 2>&1 || { echo "ERROR: perintah tidak ditemukan: $1" >&2; exit 1; }
}

# PRELOAD_ENV (mis. file skenario) dibaca lebih dulu sehingga nilainya menang atas config.
[ -n "${PRELOAD_ENV:-}" ] && load_env "$PRELOAD_ENV"
load_env "$ROOT/config/experiment.env"
