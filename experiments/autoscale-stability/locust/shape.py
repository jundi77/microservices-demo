"""Load shape bertahap untuk eksperimen autoscale.

Dipakai bersama locustfile bawaan microservices-demo:
    locust -f locustfile.py,shape.py ...

STAGES      "durasi:users durasi:users ..." (detik), contoh "180:20 300:150 300:20"
SPAWN_RATE  user per detik saat jumlah user naik/turun
Locust berhenti sendiri setelah stage terakhir selesai.
"""
import os

from locust import LoadTestShape


def parse_stages(text):
    stages, end = [], 0
    for item in text.split():
        duration, users = item.split(":")
        end += int(duration)
        stages.append((end, int(users)))
    if not stages:
        raise ValueError("STAGES kosong")
    return stages


class StagesShape(LoadTestShape):
    stages = parse_stages(os.environ.get("STAGES", "60:10"))
    spawn_rate = float(os.environ.get("SPAWN_RATE", "10"))

    def tick(self):
        run_time = self.get_run_time()
        for end, users in self.stages:
            if run_time < end:
                return users, self.spawn_rate
        return None
