#!/usr/bin/env bash
# Jalankan setelah mesin/VM yang menjalankan kind dinyalakan lagi.
# Beberapa pod bisa start sebelum API server/jaringan siap, lalu macet:
#   - linkerd-viz/tap: "Failed to initialize K8s API ... TLS handshake timeout"
#   - boutique/frontend: koneksi gRPC lama ke service lain sudah putus -> halaman 500
#   - kindnet: rentang IP pod antar-node tertukar -> pod tidak bisa saling menghubungi
# Script ini menunggu node siap, lalu me-restart yang macet saja.
. "$(dirname -- "$0")/lib.sh"

echo "Menunggu semua node Ready..."
kubectl wait --for=condition=Ready node --all --timeout=300s

# Setelah reboot, Docker bisa memberi IP berbeda ke container node kind. kindnet lalu bisa
# menulis rentang IP pod milik node lain ke CNI config-nya: pod baru mendapat IP yang salah
# dan route antar-node hilang (gejala: linkerd "service in fail-fast", frontend 500).
mismatch=0
for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    want=$(kubectl get node "$n" -o jsonpath='{.spec.podCIDR}')
    have=$(docker exec "$n" cat /etc/cni/net.d/10-kindnet.conflist 2>/dev/null | grep -o '"subnet": *"[^"]*"' | grep -o '[0-9.]*/[0-9]*')
    if [ "$want" != "$have" ]; then
        echo "kindnet $n: CNI memakai ${have:-?}, seharusnya $want"
        mismatch=1
    fi
done
if [ "$mismatch" = 1 ]; then
    echo "Restart kindnet agar CNI config ditulis ulang"
    kubectl -n kube-system rollout restart ds kindnet
    kubectl -n kube-system rollout status ds kindnet --timeout=180s
    sleep 10
    # Hapus pod yang terlanjur mendapat IP dari rentang node lain
    kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.spec.nodeName}|{.spec.hostNetwork}|{.status.podIP}{"\n"}{end}' |
    while IFS='|' read -r ns pod node hostnet ip; do
        [ -n "$ip" ] && [ "$hostnet" != true ] || continue
        cidr=$(kubectl get node "$node" -o jsonpath='{.spec.podCIDR}')
        if [ "${ip%.*}" != "${cidr%.*}" ]; then
            echo "Hapus $ns/$pod (IP $ip di luar $cidr)"
            kubectl -n "$ns" delete pod "$pod" --wait=false
        fi
    done
fi
echo "Memberi waktu 60 s untuk pod start..."
sleep 60

for p in $(kubectl get pods -A --no-headers | awk '$4 ~ /CrashLoopBackOff|Error|Unknown/ {print $1"/"$2}'); do
    ns=${p%%/*}; pod=${p##*/}
    owner=$(kubectl -n "$ns" get pod "$pod" -o jsonpath="{.metadata.ownerReferences[0].name}")
    deploy=${owner%-*}
    echo "Restart $ns/$deploy (pod $pod macet)"
    kubectl -n "$ns" rollout restart deployment "$deploy" 2>/dev/null || kubectl -n "$ns" delete pod "$pod"
done

if [ "$(curl -s -o /dev/null -w "%{http_code}" "$TARGET_URL/")" != 200 ]; then
    echo "Boutique tidak 200 -> restart frontend"
    kubectl -n "$NAMESPACE" rollout restart deployment frontend
    kubectl -n "$NAMESPACE" rollout status deployment frontend --timeout=180s
fi

sleep 10
echo
echo "Pod belum sehat: $(kubectl get pods -A --no-headers | grep -vcE "Running|Completed")"
for h in prometheus grafana linkerd boutique; do
    curl -s -o /dev/null -m 10 -w "$h %{http_code}\n" "http://$h.$HOST_IP.sslip.io/"
done
