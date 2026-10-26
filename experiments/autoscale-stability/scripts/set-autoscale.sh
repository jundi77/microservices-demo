#!/usr/bin/env bash
# Pasang mode autoscale untuk SCALE_TARGETS di namespace boutique.
#   none    replika tetap = FIXED_REPLICAS, semua HPA dihapus
#   cpu     HPA ContainerResource cpu    (container "server"), target HPA_CPU_UTILIZATION %
#   memory  HPA ContainerResource memory (container "server"), target HPA_MEMORY_UTILIZATION %
#
# ContainerResource dipakai karena sidecar linkerd-proxy tidak punya resource request;
# metrik tipe Resource menghitung seluruh pod sehingga utilisasi tidak bisa dihitung.
#
# DRY_RUN=1: hanya validasi manifest HPA di API server, cluster tidak diubah.
set -euo pipefail
. "$(dirname -- "$0")/lib.sh"
need kubectl

MODE=${1:?Usage: set-autoscale.sh none|cpu|memory}
DRY_RUN=${DRY_RUN:-0}

case "$MODE" in
    none)   ;;
    cpu)    RESOURCE=cpu;    UTILIZATION=$HPA_CPU_UTILIZATION ;;
    memory) RESOURCE=memory; UTILIZATION=$HPA_MEMORY_UTILIZATION ;;
    *) echo "Mode tidak dikenal: $MODE" >&2; exit 1 ;;
esac

if [ "$DRY_RUN" = 1 ]; then
    APPLY="kubectl apply --dry-run=server -f -"
    echo "DRY_RUN: cluster tidak diubah"
else
    APPLY="kubectl apply -f -"
    echo "Hapus HPA lama di namespace $NAMESPACE"
    kubectl -n "$NAMESPACE" delete hpa -l experiment=boutique-autoscale --ignore-not-found

    if [ "$MODE" = none ]; then
        START_REPLICAS=$FIXED_REPLICAS
    else
        START_REPLICAS=$HPA_MIN
    fi
    for d in $SCALE_TARGETS; do
        kubectl -n "$NAMESPACE" scale deployment "$d" --replicas="$START_REPLICAS"
    done
fi

if [ "$MODE" != none ]; then
    for d in $SCALE_TARGETS; do
        cat <<EOF | $APPLY
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: $d
  namespace: $NAMESPACE
  labels:
    experiment: boutique-autoscale
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: $d
  minReplicas: $HPA_MIN
  maxReplicas: $HPA_MAX
  metrics:
  - type: ContainerResource
    containerResource:
      name: $RESOURCE
      container: server
      target:
        type: Utilization
        averageUtilization: $UTILIZATION
  behavior:
    scaleDown:
      stabilizationWindowSeconds: $HPA_SCALE_DOWN_WINDOW
EOF
    done
fi

[ "$DRY_RUN" = 1 ] && exit 0

for d in $SCALE_TARGETS; do
    kubectl -n "$NAMESPACE" rollout status deployment "$d" --timeout=300s
done

echo
kubectl -n "$NAMESPACE" get deployment $SCALE_TARGETS
kubectl -n "$NAMESPACE" get hpa 2>/dev/null || true
echo "Mode autoscale aktif: $MODE"
