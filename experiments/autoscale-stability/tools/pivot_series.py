#!/usr/bin/env python3
"""Gabungkan combined.csv dengan metrik per deployment menjadi timeline.csv (format lebar).

metrics/replicas_by_deploy.csv  (series "deployment=frontend") -> kolom replicas_frontend
metrics/rps_by_app.csv          (series "app=cartservice")     -> kolom rps_cartservice
... dst untuk setiap file metrics/*_by_*.csv

Kolom *_BY_* di combined.csv (rata-rata antar deployment dari collect.py) dibuang.
"""
import csv
import sys
from pathlib import Path


def load_series(path):
    """{label_value: {detik: nilai}}"""
    series = {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            label = row["series"].split("=", 1)[-1] if row["series"] else "all"
            series.setdefault(label, {})[round(float(row["timestamp_epoch"]))] = row["value"]
    return series


def nearest(values, ts, tolerance=1):
    for delta in range(tolerance + 1):
        for t in (ts - delta, ts + delta):
            if t in values:
                return values[t]
    return ""


def main():
    exp = Path(sys.argv[1])
    with open(exp / "combined.csv", newline="") as f:
        base_rows = list(csv.DictReader(f))
    if not base_rows:
        raise SystemExit("combined.csv kosong")
    base_cols = [c for c in base_rows[0] if "_BY_" not in c]

    extra_cols, lookups = [], []
    for path in sorted((exp / "metrics").glob("*_by_*.csv")):
        prefix = path.stem.split("_by_")[0]
        for label, values in sorted(load_series(path).items()):
            extra_cols.append(f"{prefix}_{label}")
            lookups.append(values)

    with open(exp / "timeline.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(base_cols + extra_cols)
        for row in base_rows:
            ts = round(float(row["timestamp_epoch"]))
            w.writerow([row[c] for c in base_cols] + [nearest(v, ts) for v in lookups])
    print(f"timeline.csv: {len(base_rows)} baris, {len(extra_cols)} kolom per deployment")


if __name__ == "__main__":
    main()
