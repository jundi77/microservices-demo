#!/usr/bin/env bash
# Jalankan matriks eksperimen: mode autoscale x skenario x replikasi.
#   MODES="none cpu" SCENARIOS="step burst" REPLICATES=3 ./scripts/run-matrix.sh
# Urutan run diacak per replikasi supaya efek urutan (cache, JIT, sisa scale-in) tidak sistematis.
set -euo pipefail
. "$(dirname -- "$0")/lib.sh"

MODES=${MODES:-"none cpu"}
SCENARIOS=${SCENARIOS:-"step"}
REPLICATES=${REPLICATES:-3}

for r in $(seq 1 "$REPLICATES"); do
    runs=()
    for m in $MODES; do
        for s in $SCENARIOS; do
            runs+=("$s:$m")
        done
    done
    for item in $(printf '%s\n' "${runs[@]}" | shuf); do
        s=${item%%:*}
        m=${item##*:}
        echo "=== replikasi $r: skenario $s, mode $m ==="
        REPLICATE=$r "$ROOT/scripts/run-experiment.sh" "scenarios/$s.env" "$m"
    done
done

python3 "$ROOT/tools/summarize.py" --campaign "$ROOT/results"
