#!/usr/bin/env python3
"""Install private relay snapshots and Azure Monitor collection using Azure CLI.

Does not restart relay containers. Alerts are configured separately.
"""
import argparse
import base64
import json
from pathlib import Path
import re
import subprocess
import tempfile

API = '2023-03-11'


def cli(*args):
    result = subprocess.check_output(['az', *args, '--only-show-errors', '-o', 'json'], text=True)
    return json.loads(result) if result.strip() else None


def put(resource, body, version=API):
    with tempfile.NamedTemporaryFile('w', suffix='.json') as f:
        json.dump(body, f); f.flush()
        return cli('rest', '--method', 'put', '--url',
                   f'https://management.azure.com{resource}?api-version={version}',
                   '--body', '@' + f.name)


def rule(region, workspace):
    return {'location': region, 'kind': 'Linux', 'properties': {
        'dataSources': {'syslog': [{'name': 'relay', 'streams': ['Microsoft-Syslog'],
            'facilityNames': ['local0'],
            'logLevels': ['Info', 'Notice', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency']}]},
        'destinations': {'logAnalytics': [{'name': 'central', 'workspaceResourceId': workspace}]},
        'dataFlows': [{'streams': ['Microsoft-Syslog'], 'destinations': ['central'],
            'transformKql': 'source | where ProcessName == "cmux-v3"',
            'outputStream': 'Microsoft-Syslog'}]}}


def install_script():
    data = base64.b64encode(Path(__file__).with_name('observe_snapshot.py').read_bytes()).decode()
    return f'''#!/bin/bash
set -euo pipefail
DEBIAN_FRONTEND=noninteractive apt-get install -y python3 rsyslog >/var/log/cmux-v3-observe-install.log
systemctl enable --now rsyslog
printf '%s' '{data}' | base64 -d >/usr/local/bin/cmux-v3-observe
chmod 755 /usr/local/bin/cmux-v3-observe
cat >/etc/systemd/system/cmux-v3-observe.service <<'SERVICE'
[Unit]
Description=Private cmux relay health snapshot
After=network.target rsyslog.service
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/bin/cmux-v3-observe
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_UNIX
IPAddressDeny=any
IPAddressAllow=127.0.0.1/32
MemoryMax=64M
CPUQuota=10%
TimeoutStartSec=15
SERVICE
cat >/etc/systemd/system/cmux-v3-observe.timer <<'TIMER'
[Unit]
Description=Collect cmux relay health every minute
[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
[Install]
WantedBy=timers.target
TIMER
systemctl daemon-reload
systemctl enable --now cmux-v3-observe.timer
systemctl start cmux-v3-observe.service
systemctl is-active --quiet cmux-v3-observe.timer
echo CMUX_V3_OBSERVE_OK
'''


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--subscription', required=True)
    p.add_argument('--deployment', type=Path, required=True)
    p.add_argument('--workspace', required=True, help='Log Analytics workspace resource ID')
    p.add_argument('--identity', required=True, help='VM user-assigned identity resource ID')
    p.add_argument('--receipt', type=Path, required=True)
    args = p.parse_args()
    for resource in [args.workspace, args.identity]:
        if not resource.lower().startswith(f'/subscriptions/{args.subscription}/'.lower()):
            p.error('resources must belong to the selected subscription')
    workspace = cli('resource', 'show', '--ids', args.workspace, '--subscription', args.subscription)
    receipt = {'workspace': args.workspace, 'workspace_id': workspace['properties']['customerId'], 'nodes': []}
    # A DCR must share the destination workspace region; its source VMs may be
    # in other regions. Share one rule rather than duplicating regional configs.
    dcr = args.workspace.split('/providers/')[0] + '/providers/Microsoft.Insights/dataCollectionRules/cmux-v3-relay'
    put(dcr, rule(workspace['location'], args.workspace))
    for node in json.loads(args.deployment.read_text())['nodes']:
        for key in ('node', 'group', 'region'):
            if not re.fullmatch(r'[a-z0-9-]+', node[key]):
                p.error('invalid node receipt')
        if 'CMUX_V3_OK' not in node.get('installation', ''):
            p.error('node has no successful installation receipt')
        vm = cli('vm', 'show', '--subscription', args.subscription, '-g', node['group'], '-n', node['node'])
        identities = vm.get('identity', {}).get('userAssignedIdentities', {})
        if args.identity.lower() not in {key.lower() for key in identities}:
            p.error('monitor identity is not assigned to VM')
        association = vm['id'] + '/providers/Microsoft.Insights/dataCollectionRuleAssociations/cmux-v3-relay'
        put(association, {'properties': {'dataCollectionRuleId': dcr}})
        settings = {'authentication': {'managedIdentity': {
            'identifier-name': 'mi_res_id', 'identifier-value': args.identity}}}
        cli('vm', 'extension', 'set', '--subscription', args.subscription,
            '-g', node['group'], '--vm-name', node['node'],
            '--publisher', 'Microsoft.Azure.Monitor', '--name', 'AzureMonitorLinuxAgent',
            '--enable-auto-upgrade', 'true', '--settings', json.dumps(settings))
        with tempfile.NamedTemporaryFile('w', suffix='.sh') as f:
            f.write(install_script()); f.flush()
            value = cli('vm', 'run-command', 'invoke', '--subscription', args.subscription,
                '-g', node['group'], '-n', node['node'], '--command-id', 'RunShellScript', '--scripts', '@' + f.name)
        messages = '\n'.join(v.get('message', '') for v in value.get('value', []))
        if 'CMUX_V3_OBSERVE_OK' not in messages:
            raise RuntimeError('Snapshot collector did not install: ' + messages[-2000:])
        receipt['nodes'].append({'node': node['node'], 'vm': vm['id'], 'rule': dcr})
        args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
        print('MONITOR_INSTALLED', node['node'], flush=True)


if __name__ == '__main__':
    main()
