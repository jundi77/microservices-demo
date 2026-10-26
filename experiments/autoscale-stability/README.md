# Eksperimen: stabilitas throughput saat autoscale

Eksperimen ini memakai **Online Boutique** (repo ini, v0.10.7) di cluster kind + Linkerd. Strukturnya mengikuti modul `cloud-dynamics-*` Pak Roy ([rm77/cloud2023](https://github.com/rm77/cloud2023/tree/master/kubernetes)):

```
config/experiment.env     parameter global (HOST_IP, target, HPA, warm-up, dll.)
scenarios/*.env           pola beban Locust: STAGES="durasi:user ..."
locust/shape.py           LoadTestShape yang membaca STAGES
k8s/                      PodMonitor linkerd-proxy + Ingress frontend
patches/                  perbaikan collect.py Pak Roy (escape PromQL)
scripts/
  setup-venv.sh           venv Locust versi sama dengan image loadgenerator (2.43.0)
  setup-cluster-extras.sh pasang isi k8s/ ke cluster
  check-environment.sh    cek prasyarat
  set-autoscale.sh        mode none | cpu | memory
  run-experiment.sh       satu run: autoscale -> warm-up -> ukur -> cool-down -> collect
  collect.sh              Prometheus -> combined.csv, timeline.csv, summary.json
  run-matrix.sh           mode x skenario x replikasi (urutan diacak)
  cek-setelah-boot.sh     restart pod yang macet setelah mesin dinyalakan ulang
queries/boutique-metrics.env   PromQL (dipakai collect.py milik Pak Roy)
tools/                    konversi Locust, event HPA, pivot, ringkasan
results/                  satu folder per run (tidak di-commit)
```

## Desain eksperimen

| Variabel | Isi |
|---|---|
| **Independen** | mode autoscale (`none` = replika tetap, `cpu`, `memory`), pola beban (`constant`, `step`, `burst`, `periodic`) |
| **Dependen** | throughput (client: `achieved_rps`, server: `FRONTEND_RPS` dari Linkerd), CV throughput per stage, latency p95, error rate, jumlah replika & event scale |
| **Terkontrol** | versi aplikasi (v0.10.7), locustfile & versi Locust, `SCALE_TARGETS`, HPA min/max/target, durasi & jendela pengukuran, topologi cluster, Linkerd & Prometheus |

Locust bersifat *closed-loop*: setiap user menunggu respons lalu jeda 1–10 detik. Jadi saat sistem jenuh, throughput tertahan dan latency naik, sedangkan error tidak selalu ikut naik. Karena itu `rps_per_user` di ringkasan ikut dihitung: nilainya turun ketika jenuh.

**Stabilitas throughput** diukur dengan koefisien variasi (CV = std/mean) per stage beban, setelah membuang `STAGE_TRIM_SECONDS` awal tiap stage (masa transisi). `cv_10s` (rata-rata per 10 detik) lebih representatif daripada CV per detik, karena CV per detik memuat noise Poisson sekitar 1/√rps.

**Hasil dari mesin berbeda tidak boleh dicampur dalam satu perbandingan.** Titik jenuh bergantung pada CPU/RAM mesin. Bandingkan mode (`none`/`cpu`/`memory`) di dalam satu mesin. Mesin lain dipakai sebagai replikasi, bukan digabung datanya.

## HPA

`set-autoscale.sh cpu` memasang `autoscaling/v2` HPA untuk tiap deployment di `SCALE_TARGETS`. HPA ini bertipe **`ContainerResource`**, yang hanya mengukur container `server`. Tipe `Resource` biasa menghitung seluruh pod, padahal sidecar `linkerd-proxy` tidak punya resource request, sehingga utilisasi tidak bisa dihitung. `HPA_SCALE_DOWN_WINDOW=60` (default Kubernetes 300 s) dipakai supaya scale-in terlihat dalam satu run.

Mode `memory` disediakan sebagai pembanding "metric lain". Pemakaian memori jarang turun setelah naik, jadi scale-in-nya lambat atau tidak terjadi, dan itu termasuk temuan. Autoscale berbasis **RPS/latency dari Linkerd** butuh KEDA atau prometheus-adapter (belum terpasang); bisa ditambahkan sebagai mode berikutnya.

## Setup di mesin baru

Versi yang dipakai di lab referensi: kind v0.33.0 (Kubernetes v1.37.0), Linkerd edge-26.9.3, kube-prometheus-stack 92.13.1, metrics-server v0.9.0, Ubuntu 24.04 dengan RAM 26 GB dan 6 vCPU.

**1. Cluster dan komponen pendukung** memakai script Pak Roy. Ganti `<IP>` dengan IP mesinmu (bukan 127.0.0.1, karena nama `*.sslip.io` me-resolve ke IP itu):

```bash
sudo apt-get install -y python3-venv python3-pip jq git
printf "fs.inotify.max_user_instances = 8192\nfs.inotify.max_user_watches = 524288\n" | sudo tee /etc/sysctl.d/99-kind-inotify.conf && sudo sysctl --system

git clone https://github.com/rm77/cloud2023.git ~/cloud2023
cd ~/cloud2023/kubernetes/bin && sh download.sh
echo 'export PATH=$PATH:$HOME/cloud2023/kubernetes/bin' >> ~/.bashrc && source ~/.bashrc

cd ~/cloud2023/kubernetes/setup-cluster/kind
sh 1-create-cluster.sh && sh 2-set-config.sh
sudo sysctl --system          # 1-create-cluster.sh menurunkan inotify; kembalikan
kubectl wait --for=condition=Ready node --all --timeout=180s

cd ~/cloud2023/kubernetes/setup-cluster/supporting
export HOST_IP=<IP> INGRESS_HTTP_PORT=80 INGRESS_HTTPS_PORT=443
sh 3-install-ingress.sh && sh 4-cek-ingress.sh
sh 5-install-prometheus.sh
sh 6-install-linkerd.sh       # lama (10-20 menit), tunggu sampai selesai
```

**2. metrics-server** (dibutuhkan HPA; `--kubelet-insecure-tls` khusus kind):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml
kubectl -n kube-system patch deploy metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl top nodes             # tunggu ±1 menit sampai keluar angka
```

**3. Online Boutique** dari repo ini, ter-inject Linkerd:

```bash
git clone -b autoscale-experiments https://github.com/jundi77/microservices-demo.git ~/microservices-demo
kubectl create ns boutique && kubectl annotate ns boutique linkerd.io/inject=enabled
kubectl apply -n boutique -f ~/microservices-demo/release/kubernetes-manifests.yaml
kubectl -n boutique wait --for=condition=Available deploy --all --timeout=600s
```

**4. Bundle eksperimen.** Ganti `HOST_IP` di `config/experiment.env` dengan IP mesinmu, lalu:

```bash
cd ~/microservices-demo/experiments/autoscale-stability
git -C ~/cloud2023 apply "$PWD/patches/cloud2023-collect-py-escape.patch"   # collect.py asli error HTTP 400 (escape \- di PromQL)
./scripts/setup-cluster-extras.sh  # PodMonitor linkerd-proxy + Ingress boutique.<IP>.sslip.io
./scripts/setup-venv.sh            # sekali saja
./scripts/check-environment.sh     # semua harus OK
```

## Menjalankan

**1. Kalibrasi tanpa HPA.** Cari jumlah user di mana frontend mulai jenuh (latency naik, `rps_per_user` turun). Ubah `STAGES` di `scenarios/*.env` sesuai hasil kalibrasi.

```bash
./scripts/run-experiment.sh scenarios/step.env none
```

**2. Bandingkan mode** (satu run step ≈ 17 menit: 780 s pengukuran + settle, warm-up, cool-down):

```bash
./scripts/run-experiment.sh scenarios/step.env cpu
MODES="none cpu" SCENARIOS="step burst" REPLICATES=3 ./scripts/run-matrix.sh   # ±3 jam
```

Run panjang sebaiknya di dalam `tmux` supaya tidak terputus kalau SSH putus.

**3. Hasil per run** (`results/boutique-<profile>-<mode>-<waktu>-r<n>/`):

| File | Isi |
|---|---|
| `workload.csv` | per detik dari Locust: users, sent/success/failed, achieved_rps, p50/p95/p99 |
| `locust_stats*.csv`, `locust-report.html` | output asli Locust per endpoint |
| `metrics/*.csv`, `combined.csv` | output collector Pak Roy |
| `timeline.csv` | workload + metrik frontend + kolom per deployment (`replicas_*`, `hpa_desired_*`, `rps_*`, `p95_*`, `cpu_*`, `cpu_util_*`) |
| `hpa-events.csv` | kejadian `SuccessfulRescale` selama pengukuran |
| `summary.json` | CV throughput per stage, latency, error rate, scaling |
| `k8s-before.txt`, `k8s-after.txt`, `hpa.yaml` | keadaan cluster |

`results/campaign-summary.csv` merangkum semua run (dibuat `run-matrix.sh`, atau `python3 tools/summarize.py --campaign results`). Modul analisis Pak Roy juga bisa dipakai langsung:

```bash
~/cloud2023/kubernetes/research/cloud-dynamics-analysis-venv/scripts/analyze-all.sh "$PWD/results"
```

## Catatan

- `run-experiment.sh` men-scale `loadgenerator` bawaan ke 0 dan membiarkannya 0. Untuk menyalakan lagi: `kubectl -n boutique scale deploy loadgenerator --replicas=1`.
- Locust berjalan di mesin yang sama dengan node kind (sama seperti `loadgen.py` Pak Roy). Pada beban sangat tinggi, CPU Locust ikut bersaing; pantau dengan `top`.
- Request masuk lewat nginx ingress (`boutique.<HOST_IP>.sslip.io`). `FRONTEND_RPS` diukur di proxy Linkerd frontend, setelah nginx.
- Variabel apa pun di `config/experiment.env` bisa ditimpa per run, contoh `HPA_CPU_UTILIZATION=70 HPA_MAX=8 ./scripts/run-experiment.sh scenarios/burst.env cpu`.
- Setelah mesin di-restart, jalankan `./scripts/cek-setelah-boot.sh` sebelum eksperimen: frontend sering mengembalikan 500 karena koneksi gRPC lama sudah putus.
