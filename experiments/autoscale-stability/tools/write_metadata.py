#!/usr/bin/env python3
"""Tulis metadata.json untuk satu run dari variabel environment run-experiment.sh.

application.name ("frontend") dipakai collect.py Pak Roy untuk mengganti __APP__.
"""
import json
import os
import platform
import subprocess
import sys
from pathlib import Path


def main():
    out = Path(sys.argv[1])
    env = os.environ

    def num(key):
        value = env.get(key, "")
        return int(value) if value.isdigit() else (value or None)

    try:
        locust_version = subprocess.run(["locust", "--version"], capture_output=True, text=True).stdout.strip()
    except OSError:
        locust_version = None

    meta = {
        "experiment_id": env["EXPERIMENT_ID"],
        "profile": env["PROFILE"],
        "stages": env["STAGES"],
        "spawn_rate": float(env["SPAWN_RATE"]),
        "autoscale_mode": env["MODE"],
        "target_url": env["TARGET_URL"],
        "host_ip": env["HOST_IP"],
        "namespace": env["NAMESPACE"],
        "measurement_start_epoch": int(env["MEASUREMENT_START_EPOCH"]),
        "measurement_end_epoch": int(env["MEASUREMENT_END_EPOCH"]),
        "sample_interval_seconds": float(env["SAMPLE_INTERVAL"]),
        "warmup_seconds": num("WARMUP_SECONDS"),
        "warmup_users": num("WARMUP_USERS"),
        "cooldown_seconds": num("COOLDOWN_SECONDS"),
        "replicate": num("REPLICATE"),
        "locust_exit_code": num("LOCUST_RC"),
        "autoscale": {
            "scale_targets": env["SCALE_TARGETS"].split(),
            "fixed_replicas": num("FIXED_REPLICAS"),
            "hpa_min": num("HPA_MIN"),
            "hpa_max": num("HPA_MAX"),
            "hpa_cpu_utilization": num("HPA_CPU_UTILIZATION"),
            "hpa_memory_utilization": num("HPA_MEMORY_UTILIZATION"),
            "hpa_scale_down_window": num("HPA_SCALE_DOWN_WINDOW"),
        },
        "application": {"name": "frontend", "architecture": "microservices (Online Boutique)"},
        "runtime": {"python": platform.python_version(), "locust": locust_version},
    }
    (out / "metadata.json").write_text(json.dumps(meta, indent=2))


if __name__ == "__main__":
    main()
