#!/usr/bin/env python3
"""Ringkasan stabilitas throughput per run, dan rekap seluruh kampanye.

  summarize.py results/<id>           -> results/<id>/summary.json
  summarize.py --campaign results/    -> results/campaign-summary.csv

Per stage beban (dari STAGES di metadata.json), setelah membuang STAGE_TRIM_SECONDS awal:
  - throughput client (achieved_rps) dan server (FRONTEND_RPS dari Linkerd): mean, std, CV
  - CV dihitung dua kali: per 1 s (memuat noise Poisson ~1/sqrt(rps)) dan per bin 10 s
  - rps_per_user: turun saat sistem jenuh (closed-loop: user menunggu respons)
  - latency p95 client (median), error rate
Scaling: replika min/max per deployment, jumlah perubahan replika, jumlah event HPA.
"""
import csv
import json
import math
import os
import statistics
import sys
from pathlib import Path

BIN_SECONDS = 10


def num(value):
    try:
        v = float(value)
        return v if math.isfinite(v) else None
    except (TypeError, ValueError):
        return None


def describe(values):
    values = [v for v in values if v is not None]
    if not values:
        return {"n": 0, "mean": None, "std": None, "cv": None}
    mean = statistics.fmean(values)
    std = statistics.stdev(values) if len(values) > 1 else 0.0
    return {"n": len(values), "mean": mean, "std": std, "cv": std / mean if mean else None}


def binned(rows, column):
    bins = {}
    for r in rows:
        v = num(r.get(column))
        if v is not None:
            bins.setdefault(int(num(r["elapsed_s"]) // BIN_SECONDS), []).append(v)
    # hanya bin penuh agar rata-rata tiap bin sebanding
    return [statistics.fmean(v) for v in bins.values() if len(v) >= BIN_SECONDS * 0.8]


def parse_stages(text):
    stages, start = [], 0
    for item in text.split():
        duration, users = item.split(":")
        stages.append((start, start + int(duration), int(users)))
        start += int(duration)
    return stages


def summarize_run(exp, trim):
    meta = json.loads((exp / "metadata.json").read_text())
    source = exp / "timeline.csv" if (exp / "timeline.csv").exists() else exp / "workload.csv"
    with open(source, newline="") as f:
        rows = list(csv.DictReader(f))

    stage_summaries = []
    for i, (s, e, users) in enumerate(parse_stages(meta["stages"]), 1):
        window = [r for r in rows if s + trim <= num(r["elapsed_s"]) < e]
        client = describe([num(r["achieved_rps"]) for r in window])
        server = describe([num(r.get("FRONTEND_RPS")) for r in window])
        sent = sum(num(r["sent"]) or 0 for r in window)
        failed = sum(num(r["failed"]) or 0 for r in window)
        p95 = [num(r["p95_latency_ms"]) for r in window if num(r["p95_latency_ms"]) is not None]
        stage_summaries.append({
            "stage": i, "start_s": s, "end_s": e, "users": users,
            "client_rps": client,
            "client_cv_10s": describe(binned(window, "achieved_rps"))["cv"],
            "server_rps": server,
            "server_cv_10s": describe(binned(window, "FRONTEND_RPS"))["cv"],
            "rps_per_user": client["mean"] / users if client["mean"] and users else None,
            "p95_latency_ms_median": statistics.median(p95) if p95 else None,
            "error_rate": failed / sent if sent else None,
        })

    scaling = {}
    for col in (rows[0].keys() if rows else []):
        if not col.startswith("replicas_"):
            continue
        series = [num(r[col]) for r in rows if num(r[col]) is not None]
        if series:
            changes = sum(1 for a, b in zip(series, series[1:]) if a != b)
            scaling[col[len("replicas_"):]] = {"min": min(series), "max": max(series), "changes": changes}

    hpa_events = {}
    events_file = exp / "hpa-events.csv"
    if events_file.exists():
        with open(events_file, newline="") as f:
            for r in csv.DictReader(f):
                hpa_events[r["hpa"]] = hpa_events.get(r["hpa"], 0) + 1

    sent = sum(num(r["sent"]) or 0 for r in rows)
    failed = sum(num(r["failed"]) or 0 for r in rows)
    cvs_client = [st["client_cv_10s"] for st in stage_summaries if st["client_cv_10s"] is not None]
    cvs_server = [st["server_cv_10s"] for st in stage_summaries if st["server_cv_10s"] is not None]
    summary = {
        "experiment_id": meta["experiment_id"],
        "profile": meta["profile"],
        "autoscale_mode": meta["autoscale_mode"],
        "replicate": meta["replicate"],
        "stages": meta["stages"],
        "stage_trim_seconds": trim,
        "requests": sent,
        "failed": failed,
        "error_rate": failed / sent if sent else None,
        "mean_client_cv_10s": statistics.fmean(cvs_client) if cvs_client else None,
        "mean_server_cv_10s": statistics.fmean(cvs_server) if cvs_server else None,
        "per_stage": stage_summaries,
        "scaling": scaling,
        "hpa_events": hpa_events,
    }
    (exp / "summary.json").write_text(json.dumps(summary, indent=2))
    return summary


def fmt(v, digits=4):
    if v is None:
        return ""
    if isinstance(v, float):
        return str(int(v)) if v.is_integer() else f"{v:.{digits}g}"
    return v


def campaign(results):
    out = []
    for exp in sorted(results.iterdir()):
        f = exp / "summary.json"
        if not f.exists():
            continue
        s = json.loads(f.read_text())
        row = {k: fmt(s[k]) for k in ("experiment_id", "profile", "autoscale_mode", "replicate",
                                       "requests", "error_rate", "mean_client_cv_10s", "mean_server_cv_10s")}
        for st in s["per_stage"]:
            p = f"stage{st['stage']}"
            row[f"{p}_users"] = st["users"]
            row[f"{p}_client_rps"] = fmt(st["client_rps"]["mean"])
            row[f"{p}_client_cv_10s"] = fmt(st["client_cv_10s"])
            row[f"{p}_server_cv_10s"] = fmt(st["server_cv_10s"])
            row[f"{p}_p95_ms"] = fmt(st["p95_latency_ms_median"])
        row["max_replicas"] = ";".join(f"{d}={int(v['max'])}" for d, v in sorted(s["scaling"].items()) if v["max"] > 1)
        row["hpa_events"] = sum(s["hpa_events"].values())
        out.append(row)
    if not out:
        raise SystemExit("Belum ada summary.json di " + str(results))
    cols = []
    for r in out:
        cols += [c for c in r if c not in cols]
    with open(results / "campaign-summary.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(out)
    print(f"campaign-summary.csv: {len(out)} run")


def main():
    trim = int(os.environ.get("STAGE_TRIM_SECONDS", "30"))
    if len(sys.argv) == 3 and sys.argv[1] == "--campaign":
        campaign(Path(sys.argv[2]))
        return
    s = summarize_run(Path(sys.argv[1]), trim)
    print(f"{s['experiment_id']}: {fmt(s['requests'])} request, error rate {fmt(s['error_rate'])}")
    for st in s["per_stage"]:
        print(f"  stage {st['stage']} ({st['users']} user): client {fmt(st['client_rps']['mean'])} rps "
              f"cv10s={fmt(st['client_cv_10s'])}  server cv10s={fmt(st['server_cv_10s'])}  "
              f"p95={fmt(st['p95_latency_ms_median'])} ms")
    scaled = {d: v for d, v in s["scaling"].items() if v["max"] > v["min"]}
    print("  scaling:", ", ".join(f"{d} {int(v['min'])}->{int(v['max'])}" for d, v in scaled.items()) or "tidak ada")


if __name__ == "__main__":
    main()
