#!/usr/bin/env bash
# Buat venv berisi Locust dengan versi yang sama persis dengan image loadgenerator repo.
set -euo pipefail
. "$(dirname -- "$0")/lib.sh"

REQ="$(dirname -- "$LOCUSTFILE")/requirements.txt"
[ -f "$REQ" ] || { echo "Tidak ada $REQ" >&2; exit 1; }

[ -d "$ROOT/.venv" ] || python3 -m venv "$ROOT/.venv"
"$ROOT/.venv/bin/python" -m pip install --upgrade pip
"$ROOT/.venv/bin/python" -m pip install -r "$REQ"
"$ROOT/.venv/bin/locust" --version
