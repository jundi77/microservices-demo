#!/usr/bin/env bash
# Tarik metrik Prometheus untuk satu run lalu buat timeline & ringkasan stabilitas.
#   ./scripts/collect.sh results/<id>
#
# Memakai collector Pak Roy (collect.py) dengan query khusus Boutique, lalu:
#   tools/pivot_series.py -> timeline.csv (kolom per deployment: replika, RPS, CPU)
#   tools/summarize.py    -> summary.json (CV throughput per stage, scaling, latency)
set -euo pipefail
. "$(dirname -- "$0")/lib.sh"

EXP=${1:?Usage: collect.sh results/<experiment-id>}
case "$EXP" in /*) ;; *) EXP="$PWD/$EXP" ;; esac
for f in measurement-window.env workload.csv metadata.json; do
    [ -f "$EXP/$f" ] || { echo "Tidak ada $EXP/$f" >&2; exit 1; }
done

python3 "$CLOUD2023_RESEARCH/cloud-dynamics-metrics/collector/collect.py" \
    --experiment "$EXP" \
    --prometheus-url "$PROMETHEUS_URL" \
    --namespace "$NAMESPACE" \
    --queries "$ROOT/queries/boutique-metrics.env" \
    --app frontend

awk -F, 'NR > 1 && $2 != "ok" { print "WARN : query " $1 " status " $2 > "/dev/stderr" }
         NR > 1 && $2 == "ok" && $3 == 0 { print "WARN : query " $1 " tidak mengembalikan data" > "/dev/stderr" }' \
    "$EXP/metrics/collection-status.csv"

python3 "$ROOT/tools/pivot_series.py" "$EXP"
python3 "$ROOT/tools/summarize.py" "$EXP"
