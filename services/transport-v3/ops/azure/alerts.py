#!/usr/bin/env python3
"""Configure relay health alerts and query evidence, with no implicit notifications."""
import argparse
import json
from pathlib import Path
import tempfile

from observe import cli, put


def latest(nodes):
    # Explicit expected inventory catches even nodes which have never reported.
    expected = ','.join(json.dumps(node['vm'].lower()) for node in nodes)
    if not expected:
        raise ValueError('expected node inventory is empty')
    return f'''let expected = datatable(ResourceId:string)[{expected}];
expected | join kind=leftouter (
    Syslog | where TimeGenerated > ago(10m) and ProcessName == "cmux-v3"
    | extend ResourceId=tolower(_ResourceId), payload=parse_json(SyslogMessage)
    | summarize arg_max(TimeGenerated, payload) by ResourceId
) on ResourceId
'''


def queries(nodes):
    base = latest(nodes)
    return {
        'health': base + '''| extend Reason=case(
            isnull(TimeGenerated) or TimeGenerated < ago(5m), "missing_heartbeat",
            coalesce(tobool(payload.scrape_ok), false) == false, "scrape_failed",
            tobool(payload.draining) == false and toint(payload.cmux_v3_ready) != 1, "not_ready", "")
            | where Reason != "" | project ResourceId, Reason''',
        'stalled-drain': base + '''| where todouble(payload.cmux_v3_draining_seconds) > 1800
            | extend Reason="drain_over_30_minutes" | project ResourceId, Reason''',
        'resource-pressure': base + '''| extend Reason=case(
            todouble(payload.disk_free_bytes) / todouble(payload.disk_total_bytes) < 0.1, "disk_under_10_percent",
            todouble(payload.memory_available_bytes) / todouble(payload.memory_total_bytes) < 0.1, "memory_under_10_percent", "")
            | where Reason != "" | project ResourceId, Reason''',
    }


def definition(query, workspace, region, action_groups, severity):
    return {'location': region, 'properties': {
        'description': 'cmux v3 relay health from private minute snapshots',
        'enabled': True, 'severity': severity, 'scopes': [workspace],
        'evaluationFrequency': 'PT5M', 'windowSize': 'PT10M', 'autoMitigate': True,
        'criteria': {'allOf': [{'query': query, 'timeAggregation': 'Count',
            'resourceIdColumn': 'ResourceId', 'operator': 'GreaterThan', 'threshold': 0,
            'dimensions': [{'name': 'Reason', 'operator': 'Include', 'values': ['*']}],
            'failingPeriods': {'numberOfEvaluationPeriods': 1, 'minFailingPeriodsToAlert': 1}}]},
        'actions': {'actionGroups': action_groups}}}


def query(workspace_id, kql):
    with tempfile.NamedTemporaryFile('w', suffix='.json') as f:
        json.dump({'query': kql}, f); f.flush()
        return cli('rest', '--method', 'post', '--resource', 'https://api.loganalytics.io',
            '--url', f'https://api.loganalytics.azure.com/v1/workspaces/{workspace_id}/query',
            '--body', '@' + f.name)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['install', 'status'])
    p.add_argument('--receipt', type=Path, required=True, help='observe.py receipt, updated as nodes retire')
    p.add_argument('--action-group', action='append', default=[], help='Explicit Azure notification group resource ID')
    args = p.parse_args()
    receipt = json.loads(args.receipt.read_text())
    workspace = cli('resource', 'show', '--ids', receipt['workspace'])
    if args.action == 'status':
        print(json.dumps(query(receipt['workspace_id'], latest(receipt['nodes']) +
            '| project ResourceId, TimeGenerated, payload'), indent=2))
        return
    group = receipt['workspace'].split('/providers/')[0]
    for name, kql in queries(receipt['nodes']).items():
        # Prove the query actually executes before enabling alert evaluation.
        query(receipt['workspace_id'], kql)
        resource = group + '/providers/Microsoft.Insights/scheduledQueryRules/cmux-v3-' + name
        put(resource, definition(kql, receipt['workspace'], workspace['location'],
            args.action_group, 1 if name == 'health' else 2), version='2021-08-01')
        print('ALERT_INSTALLED', resource, flush=True)
    if not args.action_group:
        print('Alerts are visible in Azure Monitor; no notification destinations configured.')


if __name__ == '__main__':
    main()
