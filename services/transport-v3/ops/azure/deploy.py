#!/usr/bin/env python3
"""Provision independent relay generations using Azure CLI. Never replaces an old node.

Run from any cwd. Requires a committed workspace and a JSON map of authority public keys.
Serving keys are generated on each VM; no private signing key is sent to a relay.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def run(*args, capture=True):
    result = subprocess.run(list(args), check=True, cwd=ROOT,
                            stdout=subprocess.PIPE if capture else None, text=True)
    return result.stdout.strip() if capture else None

def az(*args):
    return json.loads(run('az', *args, '--subscription', ARGS.subscription, '--only-show-errors', '-o', 'json'))

def label(value):
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,24}', value):
        raise argparse.ArgumentTypeError('use 1..25 lowercase letters/digits/hyphens')
    return value

def script_on_vm(group, node, script):
    with tempfile.NamedTemporaryFile('w', suffix='.sh') as f:
        f.write(script); f.flush()
        result = az('vm', 'run-command', 'invoke', '-g', group, '-n', node,
                    '--command-id', 'RunShellScript', '--scripts', '@'+f.name)
    messages = '\n'.join(v.get('message','') for v in result.get('value',[]))
    if 'CMUX_V3_OK' not in messages:
        raise RuntimeError('Remote operation did not produce a success receipt: '+messages[-4000:])
    return messages

def install_script(image, proxy, hostname, address, keys, identity_client):
    # These interpolated values come from validated labels and Azure resource IDs.
    for value in (image,proxy,hostname,address,identity_client):
        if not re.fullmatch(r'[A-Za-z0-9.:/@_-]+',value): raise ValueError('invalid deployment value')
    public = base64.b64encode(json.dumps(keys).encode()).decode()
    return f'''#!/bin/bash
set -euo pipefail
cloud-init status --wait >/dev/null
command -v docker >/dev/null
install -d -m 700 /etc/cmux-v3
if [ -e /etc/cmux-v3/installed ]; then
  echo 'Existing node must not be replaced; create a new generation.' >&2
  exit 1
fi
az login --identity --username {identity_client} >/dev/null
az acr login --name {ARGS.registry} >/dev/null
docker pull {image} >/dev/null
docker pull {proxy} >/dev/null
umask 077
[ -f /etc/cmux-v3/identity ] || openssl rand -out /etc/cmux-v3/identity 32
[ -f /etc/cmux-v3/drain ] || openssl rand -out /etc/cmux-v3/drain 32
printf '%s' '{public}' | base64 -d >/etc/cmux-v3/authority.json
chown -R 10001:10001 /etc/cmux-v3
cat >/etc/cmux-v3/Caddyfile <<'CADDY'
{hostname} {{
    reverse_proxy 127.0.0.1:4002
}}
CADDY
docker run -d --name cmux-v3-relay --restart on-failure --network host \
 --read-only --cap-drop ALL --security-opt no-new-privileges \
 --memory 768m --cpus 1.5 --pids-limit 256 \
 --log-opt max-size=10m --log-opt max-file=3 \
 -v /etc/cmux-v3:/run/cmux-v3:ro {image} \
 --identity-file /run/cmux-v3/identity --authority-keys /run/cmux-v3/authority.json \
 --drain-token-file /run/cmux-v3/drain \
 --advertise /ip4/{address}/tcp/4001,/ip4/{address}/udp/4001/quic-v1,/dns4/{hostname}/tcp/443/wss >/dev/null
docker run -d --name cmux-v3-tls --restart on-failure --network host \
 --log-opt max-size=10m --log-opt max-file=3 \
 -v /etc/cmux-v3/Caddyfile:/etc/caddy/Caddyfile:ro \
 -v cmux-v3-caddy-data:/data -v cmux-v3-caddy-config:/config {proxy} >/dev/null
for attempt in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8080/readyz >/dev/null; then
    printf '%s' '{image}' >/etc/cmux-v3/installed
    curl -fsS --max-time 2 http://127.0.0.1:8080/healthz
    echo CMUX_V3_OK
    exit 0
  fi
  sleep 2
done
echo 'relay readiness failed' >&2
exit 1
'''

def main():
    keys=json.loads(ARGS.authority_keys.read_text())
    if not isinstance(keys,dict) or not 1<=len(keys)<=32 or any(not k or len(k)>128 or not re.fullmatch('[a-fA-F0-9]{64}',v) for k,v in keys.items()):
        raise ValueError('authority keys must be {key_id: 32-byte-public-key-hex}')
    sha=run('git','rev-parse','HEAD')
    if run('git','status','--porcelain','--','services/transport-v3'):
        raise RuntimeError('Commit the transport workspace before building an immutable deployment')
    shared=f'cmux-v3-{ARGS.environment}-shared'
    az('group','create','-n',shared,'-l',ARGS.regions[0],'--tags','app=cmux-transport-v3',f'environment={ARGS.environment}')
    # Create is idempotent for an existing registry; no admin password is enabled.
    registry=az('acr','create','-g',shared,'-n',ARGS.registry,'--sku','Basic','--admin-enabled','false')
    build_tag=f'relay:{sha}'
    run('az','acr','build','--subscription',ARGS.subscription,'-r',ARGS.registry,'-t',build_tag,'-f','Dockerfile',str(ROOT),capture=False)
    digest=az('acr','repository','show','-n',ARGS.registry,'--image',build_tag)['digest']
    image=f'{registry["loginServer"]}/relay@{digest}'
    az('acr','import','-n',ARGS.registry,'--source','docker.io/library/caddy:2.11.4','--image','caddy:2.11.4')
    proxy_digest=az('acr','repository','show','-n',ARGS.registry,'--image','caddy:2.11.4')['digest']
    proxy=f'{registry["loginServer"]}/caddy@{proxy_digest}'
    identity=az('identity','create','-g',shared,'-n','relay-pull','-l',ARGS.regions[0])
    az('role','assignment','create','--assignee-object-id',identity['principalId'],'--assignee-principal-type','ServicePrincipal','--role','AcrPull','--scope',registry['id'])
    receipt={'source':sha,'image':image,'proxy':proxy,'nodes':[]}
    for region in ARGS.regions:
        group=f'cmux-v3-{ARGS.environment}-{region}'
        node=f'v3-{ARGS.environment}-{region}-{ARGS.generation}'
        az('group','create','-n',group,'-l',region,'--tags','app=cmux-transport-v3',f'environment={ARGS.environment}')
        nsg=az('network','nsg','create','-g',group,'-n',node+'-nsg','-l',region)
        # No public SSH or management ports. Operations use Azure authenticated Run Command.
        for index,(protocol,ports) in enumerate([('Tcp',['80','443','4001']),('Udp',['4001'])]):
            az('network','nsg','rule','create','-g',group,'--nsg-name',node+'-nsg','-n','relay-'+protocol,'--priority',str(100+index),
               '--access','Allow','--direction','Inbound','--protocol',protocol,'--source-address-prefixes','Internet',
               '--destination-port-ranges',*ports)
        public=az('network','public-ip','create','-g',group,'-n',node+'-ip','-l',region,'--sku','Standard','--allocation-method','Static','--dns-name',node)['publicIp']
        bootstrap='#cloud-config\npackage_update: true\npackages: [docker.io, azure-cli, ca-certificates, curl, openssl]\nruncmd:\n  - systemctl enable --now docker\n'
        with tempfile.NamedTemporaryFile('w',suffix='.yaml') as f:
            f.write(bootstrap);f.flush()
            az('vm','create','-g',group,'-n',node,'-l',region,'--image','Ubuntu2404','--size',ARGS.size,
               '--admin-username','azureuser','--ssh-key-values',str(ARGS.ssh_key),'--assign-identity',identity['id'],
               '--public-ip-address',node+'-ip','--nsg',node+'-nsg','--nsg-rule','NONE','--custom-data',f.name,
               '--tags','app=cmux-transport-v3',f'generation={ARGS.generation}',f'source={sha}')
        public=az('network','public-ip','show','-g',group,'-n',node+'-ip')
        script=install_script(image,proxy,public['dnsSettings']['fqdn'],public['ipAddress'],keys,identity['clientId'])
        result=script_on_vm(group,node,script)
        receipt['nodes'].append({'group':group,'node':node,'region':region,'ip':public['ipAddress'],'hostname':public['dnsSettings']['fqdn'],'installation':result})
        ARGS.receipt.write_text(json.dumps(receipt,indent=2)+'\n')
        print('INSTALLED',node,public['dnsSettings']['fqdn'],flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--subscription',required=True)
    parser.add_argument('--registry',required=True,type=label)
    parser.add_argument('--environment',default='staging',type=label)
    parser.add_argument('--generation',required=True,type=label)
    parser.add_argument('--regions',nargs='+',default=['eastus','westeurope'],type=label)
    parser.add_argument('--size',default='Standard_B2s')
    parser.add_argument('--authority-keys',required=True,type=Path)
    parser.add_argument('--ssh-key',required=True,type=Path)
    parser.add_argument('--receipt',required=True,type=Path)
    ARGS=parser.parse_args()
    main()
