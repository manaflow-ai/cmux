#!/usr/bin/env python3
"""Execute alert queries against synthetic rows in Azure's real query engine."""
import argparse
import json
from pathlib import Path

from alerts import queries, query


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--receipt', type=Path, required=True)
    args = p.parse_args()
    receipt = json.loads(args.receipt.read_text())
    cases = ['healthy', 'missing', 'stale', 'scrape-failed', 'not-ready', 'draining', 'disk', 'memory']
    nodes = [{'vm': '/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/' + name} for name in cases]
    rows = []
    for node, name in zip(nodes, cases):
        if name == 'missing':
            continue
        payload = {'scrape_ok': name != 'scrape-failed',
            'cmux_v3_ready': int(name not in ['not-ready', 'draining']),
            'draining': name == 'draining',
            'cmux_v3_draining_seconds': 1900 if name == 'draining' else 0,
            'disk_free_bytes': 5 if name == 'disk' else 90, 'disk_total_bytes': 100,
            'memory_available_bytes': 5 if name == 'memory' else 90, 'memory_total_bytes': 100}
        rows.append(','.join([str(6 if name == 'stale' else 0), json.dumps('cmux-v3'),
            json.dumps(node['vm']), json.dumps(json.dumps(payload))]))
    # A local query variable shadows the real table; no test events are ingested.
    source = 'let Syslog=datatable(Age:long,ProcessName:string,_ResourceId:string,SyslogMessage:string)[' + ','.join(rows) + '] | extend TimeGenerated=now()-Age*1m;\n'
    expected = {'health': ['missing_heartbeat', 'missing_heartbeat', 'not_ready', 'scrape_failed'],
        'stalled-drain': ['drain_over_30_minutes'],
        'resource-pressure': ['disk_under_10_percent', 'memory_under_10_percent']}
    for name, kql in queries(nodes).items():
        result = query(receipt['workspace_id'], source + kql)
        actual = sorted(row[1] for row in result['tables'][0]['rows'])
        if actual != sorted(expected[name]):
            raise RuntimeError(f'{name}: expected {expected[name]}, received {actual}')
        print(name, 'query behavior passed')


if __name__ == '__main__':
    main()
