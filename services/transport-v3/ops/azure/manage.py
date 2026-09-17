#!/usr/bin/env python3
"""Read private relay health/metrics or request authenticated drain using Azure CLI."""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=['status','drain'])
    p.add_argument('--subscription',required=True)
    p.add_argument('--group',required=True)
    p.add_argument('--node',required=True)
    p.add_argument('--replacement-receipt',type=Path)
    args=p.parse_args()
    if args.action=='drain':
        # Never take the only known generation out of service during an upgrade.
        if args.replacement_receipt is None: p.error('drain requires the healthy replacement generation receipt')
        replacement=json.loads(args.replacement_receipt.read_text())
        nodes=replacement.get('nodes',[])
        if len(nodes)<2 or any(n.get('node')==args.node for n in nodes): p.error('replacement must contain two distinct new nodes')
        for node in nodes:
            if 'CMUX_V3_OK' not in node.get('installation',''): p.error('missing replacement installation receipt')
        # Installation receipts alone cannot authorize a drain after a replacement failure.
        for node in nodes:
            with tempfile.NamedTemporaryFile('w',suffix='.sh') as f:
                f.write('set -eu\ncurl -fsS --max-time 3 http://127.0.0.1:8080/readyz >/dev/null\necho CMUX_V3_READY\n');f.flush()
                result=json.loads(subprocess.check_output(['az','vm','run-command','invoke','--subscription',args.subscription,'-g',node['group'],'-n',node['node'],'--command-id','RunShellScript','--scripts','@'+f.name,'--only-show-errors','-o','json'],text=True))
            if not any('CMUX_V3_READY' in v.get('message','') for v in result.get('value',[])):
                raise RuntimeError('Replacement is not ready; old generation stays active')
        print('Replacement readiness rechecked. Old circuits will finish before exit.')
    script='''#!/bin/bash
set -euo pipefail
curl -fsS --max-time 3 http://127.0.0.1:8080/healthz
curl -fsS --max-time 3 http://127.0.0.1:8080/metrics
'''
    if args.action=='drain':
        script+='''token=$(od -An -v -tx1 /etc/cmux-v3/drain | tr -d ' \\n')
curl -fsS --max-time 3 -X POST -H "Authorization: Bearer $token" http://127.0.0.1:8080/drain
'''
    script+='echo CMUX_V3_OK\n'
    with tempfile.NamedTemporaryFile('w',suffix='.sh') as f:
        f.write(script);f.flush()
        value=json.loads(subprocess.check_output(['az','vm','run-command','invoke','--subscription',args.subscription,'-g',args.group,'-n',args.node,'--command-id','RunShellScript','--scripts','@'+f.name,'--only-show-errors','-o','json'],text=True))
    message='\n'.join(v.get('message','') for v in value.get('value',[]))
    if 'CMUX_V3_OK' not in message: raise RuntimeError('Relay operation failed: '+message)
    print(message)

if __name__=='__main__': main()
