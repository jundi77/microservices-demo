#!/usr/bin/env python3
"""Baca `kubectl get events --field-selector reason=SuccessfulRescale -o json` dari stdin,
tulis CSV kejadian scale HPA sejak epoch START (argumen 1).

Kolom: time_utc, epoch, hpa, new_size, message
"""
import csv
import json
import re
import sys
from datetime import datetime


def event_time(item):
    for value in (item.get("lastTimestamp"), item.get("eventTime"),
                  (item.get("series") or {}).get("lastObservedTime"), item.get("firstTimestamp")):
        if value:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
    return None


def main():
    start = int(sys.argv[1])
    items = json.load(sys.stdin).get("items", [])
    rows = []
    for item in items:
        t = event_time(item)
        if t is None or t.timestamp() < start:
            continue
        message = item.get("message") or item.get("note") or ""
        size = re.search(r"New size: (\d+)", message)
        rows.append([t.strftime("%Y-%m-%dT%H:%M:%SZ"), int(t.timestamp()),
                     item.get("involvedObject", {}).get("name", ""),
                     size.group(1) if size else "", message])
    rows.sort()
    w = csv.writer(sys.stdout)
    w.writerow(["time_utc", "epoch", "hpa", "new_size", "message"])
    w.writerows(rows)


if __name__ == "__main__":
    main()
