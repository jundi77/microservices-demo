#!/usr/bin/env bash
# Satu run eksperimen: mode autoscale + skenario beban Locust.
#   ./scripts/run-experiment.sh scenarios/step.env cpu
#
# Fase: reset replika & pasang HPA -> settle -> warm-up -> pengukuran (shape STAGES) -> cool-down -> collect
# Hasil di results/<id>/ kompatibel dengan collector Pak Roy
# (workload.csv, metadata.json, measurement-window.env).
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 scenarios/<skenario>.env none|cpu|memory" >&2
    exit 2
fi

SCENARIO=$1
MODE=$2
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "$SCENARIO" in /*) ;; *) SCENARIO="$SCRIPT_DIR/../$SCENARIO" ;; esac
[ -f "$SCENARIO" ] || { echo "Skenario tidak ada: $SCENARIO" >&2; exit 1; }

# Urutan prioritas: variabel pemanggil > skenario > config/experiment.env
PRELOAD_ENV="$SCENARIO" . "$SCRIPT_DIR/lib.sh"
export MODE

"$ROOT/scripts/check-environment.sh"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
export EXPERIMENT_ID="boutique-${PROFILE}-${MODE}-${STAMP}-r${REPLICATE}"
OUT="$ROOT/results/$EXPERIMENT_ID"
mkdir -p "$OUT"
cp "$ROOT/config/experiment.env" "$OUT/experiment.env"
cp "$SCENARIO" "$OUT/scenario.env"
LOG="$OUT/run.log"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }

log "experiment_id=$EXPERIMENT_ID profile=$PROFILE mode=$MODE stages=\"$STAGES\" target=$TARGET_URL"

log "Matikan loadgenerator bawaan agar tidak ada trafik lain"
kubectl -n "$NAMESPACE" scale deployment loadgenerator --replicas=0 >>"$LOG" 2>&1 || true

log "Pasang mode autoscale: $MODE"
"$ROOT/scripts/set-autoscale.sh" "$MODE" >>"$LOG" 2>&1
log "Settle ${SETTLE_SECONDS}s"
sleep "$SETTLE_SECONDS"

kubectl -n "$NAMESPACE" get deployment,hpa -o wide > "$OUT/k8s-before.txt" 2>&1 || true

log "Warm-up ${WARMUP_SECONDS}s dengan ${WARMUP_USERS} user (tidak direkam)"
locust -f "$LOCUSTFILE" --headless --host "$TARGET_URL" \
    -u "$WARMUP_USERS" -r "$SPAWN_RATE" -t "${WARMUP_SECONDS}s" --only-summary \
    > "$OUT/warmup.log" 2>&1 || true

export MEASUREMENT_START_EPOCH=$(date +%s)
log "Pengukuran mulai: $MEASUREMENT_START_EPOCH"
set +e
locust -f "$LOCUSTFILE,$ROOT/locust/shape.py" --headless --host "$TARGET_URL" \
    --csv "$OUT/locust" --csv-full-history --html "$OUT/locust-report.html" --only-summary \
    > "$OUT/locust.log" 2>&1
export LOCUST_RC=$?
set -e
export MEASUREMENT_END_EPOCH=$(date +%s)
# Locust keluar dengan kode 1 bila ada request gagal; itu data, bukan error runner.
log "Pengukuran selesai: $MEASUREMENT_END_EPOCH (locust rc=$LOCUST_RC)"

cat > "$OUT/measurement-window.env" <<EOF
EXPERIMENT_ID=$EXPERIMENT_ID
MEASUREMENT_START_EPOCH=$MEASUREMENT_START_EPOCH
MEASUREMENT_END_EPOCH=$MEASUREMENT_END_EPOCH
SAMPLE_INTERVAL=$SAMPLE_INTERVAL
EOF

kubectl -n "$NAMESPACE" get deployment,hpa -o wide > "$OUT/k8s-after.txt" 2>&1 || true
kubectl -n "$NAMESPACE" get hpa -o yaml > "$OUT/hpa.yaml" 2>&1 || true

# Kejadian scale HPA selama pengukuran
kubectl -n "$NAMESPACE" get events --field-selector reason=SuccessfulRescale -o json 2>/dev/null \
    | python3 "$ROOT/tools/hpa_events.py" "$MEASUREMENT_START_EPOCH" > "$OUT/hpa-events.csv" || true

python3 "$ROOT/tools/locust_to_workload.py" "$OUT"

python3 "$ROOT/tools/write_metadata.py" "$OUT"

log "Cool-down ${COOLDOWN_SECONDS}s"
sleep "$COOLDOWN_SECONDS"

if [ "$AUTO_COLLECT" = 1 ]; then
    log "Collect metrik Prometheus"
    "$ROOT/scripts/collect.sh" "$OUT" 2>&1 | tee -a "$LOG"
fi

log "Selesai: $OUT"
