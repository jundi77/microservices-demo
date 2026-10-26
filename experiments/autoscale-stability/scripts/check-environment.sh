#!/usr/bin/env bash
# Pastikan semua prasyarat siap sebelum mengambil data.
set -euo pipefail
. "$(dirname -- "$0")/lib.sh"

fail=0
ok()  { echo "OK   : $*"; }
bad() { echo "ERROR: $*" >&2; fail=1; }

for c in kubectl curl python3 locust; do
    command -v "$c" >/dev/null 2>&1 && ok "perintah $c" || bad "perintah $c tidak ada (locust: jalankan ./scripts/setup-venv.sh)"
done

curl -fsS --max-time 10 "$TARGET_URL/" >/dev/null && ok "frontend $TARGET_URL" || bad "frontend tidak bisa diakses: $TARGET_URL"
curl -fsS --max-time 10 "$PROMETHEUS_URL/-/ready" >/dev/null && ok "Prometheus $PROMETHEUS_URL" || bad "Prometheus tidak ready: $PROMETHEUS_URL"

kubectl top nodes >/dev/null 2>&1 && ok "metrics-server (dibutuhkan HPA)" || bad "metrics API belum tersedia"

[ -f "$LOCUSTFILE" ] && ok "locustfile $LOCUSTFILE" || bad "locustfile tidak ada: $LOCUSTFILE"

COLLECT="$CLOUD2023_RESEARCH/cloud-dynamics-metrics/collector/collect.py"
if [ ! -f "$COLLECT" ]; then
    bad "collector Pak Roy tidak ada: $COLLECT"
elif ! grep -q 're.escape(app).replace(' "$COLLECT"; then
    bad "collect.py belum diperbaiki (escape PromQL), pasang patches/cloud2023-collect-py-escape.patch"
else
    ok "collector $COLLECT"
fi

kubectl get podmonitor -n monitoring linkerd-proxy >/dev/null 2>&1 && ok "PodMonitor linkerd-proxy" || bad "PodMonitor linkerd-proxy belum ada (jalankan ./scripts/setup-cluster-extras.sh)"

for d in $SCALE_TARGETS; do
    kubectl -n "$NAMESPACE" get deployment "$d" >/dev/null 2>&1 || bad "deployment $d tidak ada di $NAMESPACE"
done
ok "deployment target: $SCALE_TARGETS"

LG=$(kubectl -n "$NAMESPACE" get deployment loadgenerator -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
if [ "${LG:-0}" != 0 ]; then
    echo "WARN : loadgenerator bawaan masih jalan ($LG replika); run-experiment.sh akan men-scale ke 0"
fi

[ "$fail" -eq 0 ] || { echo "Lingkungan belum siap." >&2; exit 1; }
echo "Lingkungan siap."
