#!/usr/bin/env bash
# Pasang tambahan cluster yang dibutuhkan eksperimen (sekali saja per cluster):
#   - PodMonitor linkerd-proxy: Prometheus men-scrape metrik sidecar Linkerd (RPS/latency per service)
#   - Ingress frontend: Boutique bisa diakses di http://boutique.<HOST_IP>.sslip.io
# HOST_IP diambil dari config/experiment.env.
set -euo pipefail
. "$(dirname -- "$0")/lib.sh"

kubectl apply -f "$ROOT/k8s/linkerd-proxy-podmonitor.yaml"
sed "s/__HOST_IP__/$HOST_IP/" "$ROOT/k8s/boutique-ingress.yaml" | kubectl apply -n "$NAMESPACE" -f -
echo "Boutique: $TARGET_URL"
