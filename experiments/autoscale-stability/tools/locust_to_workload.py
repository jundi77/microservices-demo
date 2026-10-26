#!/usr/bin/env python3
"""Ubah locust_stats_history.csv (baris "Aggregated") menjadi workload.csv per detik.

Nama kolom mengikuti workload.csv Pak Roy sejauh mungkin sehingga collect.py dan
analyze.py bisa dipakai apa adanya:

  timestamp_epoch, elapsed_s, users, sent, success, failed, achieved_rps,
  locust_current_rps, p50_latency_ms, p95_latency_ms, p99_latency_ms

sent/success/failed = request yang selesai pada interval itu (selisih Total Request Count).
Persentil latency = jendela bergerak ~10 s milik Locust, bukan per detik murni.
"""
import csv
import sys
from pathlib import Path

COLUMNS = ["timestamp_epoch", "elapsed_s", "users", "sent", "success", "failed",
           "achieved_rps", "locust_current_rps", "p50_latency_ms", "p95_latency_ms", "p99_latency_ms"]


def read_env(path):
    out = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def number(value):
    # Locust menulis "N/A" ketika belum ada request
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def fmt(value, digits=3):
    return "" if value is None else f"{value:.{digits}f}"


def main():
    exp = Path(sys.argv[1])
    window = read_env(exp / "measurement-window.env")
    start = int(window["MEASUREMENT_START_EPOCH"])
    end = int(window["MEASUREMENT_END_EPOCH"])

    history = exp / "locust_stats_history.csv"
    if not history.exists():
        raise SystemExit(f"Tidak ada {history}; lihat {exp / 'locust.log'}")

    by_second = {}
    with open(history, newline="") as f:
        for row in csv.DictReader(f):
            if row["Name"] == "Aggregated":
                by_second[int(row["Timestamp"])] = row  # simpan baris terakhir tiap detik

    rows = []
    prev_ts, prev_total, prev_fail = start, 0, 0
    for ts in sorted(by_second):
        if ts < start or ts > end:
            continue
        r = by_second[ts]
        total = int(number(r["Total Request Count"]) or 0)
        fail = int(number(r["Total Failure Count"]) or 0)
        dt = max(ts - prev_ts, 1)
        sent, failed = total - prev_total, fail - prev_fail
        rows.append({
            "timestamp_epoch": ts,
            "elapsed_s": ts - start,
            "users": int(number(r["User Count"]) or 0),
            "sent": sent,
            "success": sent - failed,
            "failed": failed,
            "achieved_rps": fmt(sent / dt),
            "locust_current_rps": fmt(number(r["Requests/s"])),
            "p50_latency_ms": fmt(number(r["50%"]), 1),
            "p95_latency_ms": fmt(number(r["95%"]), 1),
            "p99_latency_ms": fmt(number(r["99%"]), 1),
        })
        prev_ts, prev_total, prev_fail = ts, total, fail

    if not rows:
        raise SystemExit("Tidak ada baris Locust di dalam jendela pengukuran")

    with open(exp / "workload.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        w.writeheader()
        w.writerows(rows)
    print(f"workload.csv: {len(rows)} baris, {prev_total} request, {prev_fail} gagal")


if __name__ == "__main__":
    main()
