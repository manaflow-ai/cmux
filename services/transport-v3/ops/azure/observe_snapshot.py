#!/usr/bin/env python3
"""Emit one bounded, allowlisted local relay snapshot through syslog.

Runs without root or Docker access. Never serializes response bodies or exceptions.
Azure Monitor Agent forwards local0/cmux-v3 to the central workspace.
"""
import json
import math
import os
from pathlib import Path
import shutil
import syslog
import time
import urllib.request

METRICS = {
    'cmux_v3_reservations', 'cmux_v3_circuits', 'cmux_v3_connections',
    'cmux_v3_ready', 'cmux_v3_draining_seconds',
    'cmux_v3_auth_accepted_total', 'cmux_v3_auth_denied_total',
    'cmux_v3_reservation_denied_total', 'cmux_v3_circuit_denied_total',
}
OPTIONAL_METRICS = {
    'cmux_v3_feed_sequence', 'cmux_v3_feed_healthy', 'cmux_v3_feed_failures_total',
}
LIMIT = 65536


def read_local(path):
    # Ignore HTTP_PROXY and never redirect a private scrape to another host.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open('http://127.0.0.1:8080/' + path, timeout=2) as response:
        data = response.read(LIMIT + 1)
        if len(data) > LIMIT:
            raise ValueError('oversized local response')
        return data.decode('utf-8')


def parse_metrics(body):
    result = {}
    for line in body.splitlines():
        parts = line.split()
        if len(parts) != 2 or parts[0] not in METRICS | OPTIONAL_METRICS:
            continue
        value = float(parts[1])
        if not math.isfinite(value) or value < 0 or parts[0] in result:
            raise ValueError('invalid metric')
        result[parts[0]] = value
    if not METRICS.issubset(result):
        raise ValueError('missing metric')
    for name in OPTIONAL_METRICS:
        result.setdefault(name, -1.0)
    return result


def snapshot(reader=read_local):
    result = {'schema': 1, 'observed_at': int(time.time()), 'scrape_ok': False}
    try:
        metrics = parse_metrics(reader('metrics'))
        health = json.loads(reader('healthz'))
        if not isinstance(health, dict) or type(health.get('draining')) is not bool:
            raise ValueError('invalid health')
        result.update(metrics)
        result.update(draining=health['draining'], scrape_ok=True)
    except (ValueError, OSError):
        # A failed scrape must still generate a heartbeat, without error contents.
        pass
    usage = shutil.disk_usage('/')
    result.update(disk_free_bytes=usage.free, disk_total_bytes=usage.total,
                  load_1m=os.getloadavg()[0])
    try:
        memory = dict(line.split(':', 1) for line in Path('/proc/meminfo').read_text().splitlines())
        result['memory_available_bytes'] = int(memory['MemAvailable'].split()[0]) * 1024
        result['memory_total_bytes'] = int(memory['MemTotal'].split()[0]) * 1024
    except (OSError, KeyError, ValueError):
        pass
    return result


if __name__ == '__main__':
    syslog.openlog('cmux-v3', facility=syslog.LOG_LOCAL0)
    result = snapshot()
    syslog.syslog(syslog.LOG_INFO if result['scrape_ok'] else syslog.LOG_ERR,
                  json.dumps(result, separators=(',', ':'), allow_nan=False))
