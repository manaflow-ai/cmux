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
import secrets
import subprocess
import tempfile
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]

def run(*args, capture=True):
    result = subprocess.run(list(args), check=True, cwd=ROOT,
                            stdout=subprocess.PIPE if capture else None, text=True)
    return result.stdout.strip() if capture else None

def az(*args):
    output=run('az', *args, '--subscription', ARGS.subscription, '--only-show-errors', '-o', 'json')
    return json.loads(output) if output else None

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

def install_script(image, proxy, hostname, address, keys, identity_client, feed_token, control_url):
    # These interpolated values come from validated labels and Azure resource IDs.
    for value in (image,proxy,hostname,address,identity_client,feed_token):
        if not re.fullmatch(r'[A-Za-z0-9.:/@_-]+',value): raise ValueError('invalid deployment value')
    if control_url is not None and not re.fullmatch(r'https://[A-Za-z0-9._:/@_-]+', control_url.rstrip('/')):
        raise ValueError('control URL must be HTTPS')
    public_bytes=json.dumps(keys,sort_keys=True).encode()
    public = base64.b64encode(public_bytes).decode()
    public_hash=hashlib.sha256(public_bytes).hexdigest()
    return f'''#!/bin/bash
set -euo pipefail
# Wait for package-manager ownership to leave cloud-init. Its persistent error
# report is historical; reconcile our actual dependencies before claiming ready.
cloud-init status --wait >/var/log/cmux-v3-cloud-init-status.log || true
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io ca-certificates curl openssl gnupg >/var/log/cmux-v3-runtime-install.log
command -v docker >/dev/null
systemctl enable --now docker
install -d -m 700 /etc/cmux-v3
if [ -e /etc/cmux-v3/installed ]; then
  if [ "$(cat /etc/cmux-v3/installed)" != '{image}' ]; then
    echo 'Existing node must not be replaced; create a new generation.' >&2
    exit 1
  fi
  actual_keys=$(sha256sum /etc/cmux-v3/authority.json | cut -d' ' -f1)
  if [ "$actual_keys" != '{public_hash}' ]; then
    echo 'Existing authority keys differ; use a new generation.' >&2
    exit 1
  fi
  curl -fsS --max-time 3 http://127.0.0.1:8080/readyz >/dev/null
  curl -fsS --max-time 3 http://127.0.0.1:8080/healthz
  echo CMUX_V3_OK
  exit 0
fi
if ! command -v az >/dev/null; then
  install -d -m 755 /etc/apt/keyrings
  curl -fsS https://packages.microsoft.com/keys/microsoft.asc -o /etc/apt/keyrings/microsoft.asc
  gpg --batch --yes --dearmor -o /etc/apt/keyrings/microsoft.gpg /etc/apt/keyrings/microsoft.asc
  chmod 644 /etc/apt/keyrings/microsoft.gpg
  printf '%s\\n' 'deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ noble main' >/etc/apt/sources.list.d/azure-cli.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y azure-cli >/var/log/cmux-v3-cli-install.log
fi
az login --identity --client-id {identity_client} >/dev/null
az acr login --name {ARGS.registry} >/dev/null
docker pull {image} >/dev/null
docker pull {proxy} >/dev/null
umask 077
[ -f /etc/cmux-v3/identity ] || openssl rand -out /etc/cmux-v3/identity 32
[ -f /etc/cmux-v3/drain ] || openssl rand -out /etc/cmux-v3/drain 32
printf '%s' '{public}' | base64 -d >/etc/cmux-v3/authority.json
printf '%s' '{feed_token}' >/etc/cmux-v3/feed-token
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
 --advertise /ip4/{address}/tcp/4001,/ip4/{address}/udp/4001/quic-v1,/dns4/{hostname}/tcp/443/wss \
 {('--control-url ' + control_url + ' --control-token-file /run/cmux-v3/feed-token') if control_url else ''} >/dev/null
docker run -d --name cmux-v3-tls --restart on-failure --network host \
 --log-opt max-size=10m --log-opt max-file=3 \
 -v /etc/cmux-v3/Caddyfile:/etc/caddy/Caddyfile:ro \
 -v cmux-v3-caddy-data:/data -v cmux-v3-caddy-config:/config {proxy} >/dev/null
for attempt in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8080/readyz >/dev/null; then
    printf '%s' '{image}' >/etc/cmux-v3/installed
    health=$(curl -fsS --max-time 2 http://127.0.0.1:8080/healthz)
    printf '%s\n' "$health"
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
    deployment_sha=run('git','rev-parse','HEAD')
    sha=ARGS.built_sha or deployment_sha
    if not re.fullmatch(r'[0-9a-f]{40}',sha): raise ValueError('image revision must be a full Git SHA')
    if run('git','status','--porcelain','--','.'):
        raise RuntimeError('Commit the transport workspace before building an immutable deployment')
    shared=f'cmux-v3-{ARGS.environment}-shared'
    az('group','create','-n',shared,'-l',ARGS.regions[0],'--tags','app=cmux-transport-v3',f'environment={ARGS.environment}')
    # Create is idempotent for an existing registry; no admin password is enabled.
    registry=az('acr','create','-g',shared,'-n',ARGS.registry,'--sku','Basic','--admin-enabled','false')
    build_tag=f'relay:{sha}'
    if not ARGS.built_sha:
        run('az','acr','build','--subscription',ARGS.subscription,'-r',ARGS.registry,'-t',build_tag,'-f','Dockerfile',str(ROOT),capture=False)
    digest=az('acr','repository','show','-n',ARGS.registry,'--image',build_tag)['digest']
    image=f'{registry["loginServer"]}/relay@{digest}'
    tags=az('acr','repository','list','-n',ARGS.registry)
    if 'caddy' not in tags:
        az('acr','import','-n',ARGS.registry,'--source','docker.io/library/caddy:2.11.4','--image','caddy:2.11.4')
    proxy_digest=az('acr','repository','show','-n',ARGS.registry,'--image','caddy:2.11.4')['digest']
    proxy=f'{registry["loginServer"]}/caddy@{proxy_digest}'
    identity=az('identity','create','-g',shared,'-n','relay-pull','-l',ARGS.regions[0])
    az('role','assignment','create','--assignee-object-id',identity['principalId'],'--assignee-principal-type','ServicePrincipal','--role','AcrPull','--scope',registry['id'])
    receipt={'source':sha,'deployment_source':deployment_sha,'image':image,'proxy':proxy,'nodes':[]}
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
        bootstrap='#cloud-config\npackage_update: true\npackages: [docker.io, gnupg, ca-certificates, curl, openssl]\nruncmd:\n  - systemctl enable --now docker\n'
        existing=[vm for vm in az('vm','list','-g',group) if vm['name']==node]
        if existing and existing[0].get('tags',{}).get('source')!=sha:
            raise RuntimeError('Existing generation belongs to another source revision')
        with tempfile.NamedTemporaryFile('w',suffix='.yaml') as f:
            f.write(bootstrap);f.flush()
            if not existing: az('vm','create','-g',group,'-n',node,'-l',region,'--image','Ubuntu2404','--size',ARGS.size,
               '--admin-username','azureuser','--ssh-key-values',str(ARGS.ssh_key),'--assign-identity',identity['id'],
               '--public-ip-address',node+'-ip','--nsg',node+'-nsg','--nsg-rule','NONE','--custom-data',f.name,
               '--tags','app=cmux-transport-v3',f'generation={ARGS.generation}',f'source={sha}')
        public=az('network','public-ip','show','-g',group,'-n',node+'-ip')
        feed_token = secrets.token_hex(32)
        control_url = ARGS.control_url.rstrip('/') if ARGS.control_url else None
        script=install_script(image,proxy,public['dnsSettings']['fqdn'],public['ipAddress'],keys,identity['clientId'],feed_token,control_url)
        result=script_on_vm(group,node,script)
        peer_match = re.search(r'\"peer_id\"\s*:\s*\"([^\"]+)\"', result)
        if not peer_match:
            raise RuntimeError('Relay did not return its authenticated peer id')
        peer_id = peer_match.group(1)
        addresses = [
            f"/ip4/{public['ipAddress']}/tcp/4001/p2p/{peer_id}",
            f"/ip4/{public['ipAddress']}/udp/4001/quic-v1/p2p/{peer_id}",
            f"/dns4/{public['dnsSettings']['fqdn']}/tcp/443/wss/p2p/{peer_id}",
        ]
        registration = None
        if ARGS.control_url:
            token = ARGS.control_token_file.read_text().strip()
            if not token or len(token) > 8192:
                raise RuntimeError('control token file is empty or too large')
            body = json.dumps({'team': ARGS.control_team, 'peer_id': peer_id, 'region': region, 'addresses': addresses, 'feed_token': feed_token}).encode()
            request = urllib.request.Request(
                control_url + '/v3/relays/register', data=body, method='POST',
                headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
            )
            try:
                with urllib.request.urlopen(request, timeout=10) as response:
                    if response.status < 200 or response.status >= 300:
                        raise RuntimeError(f'control relay registration returned HTTP {response.status}')
                    registration = json.loads(response.read())
            except (urllib.error.URLError, ValueError) as error:
                raise RuntimeError(f'control relay registration failed: {error}') from error
        receipt['nodes'].append({'group':group,'node':node,'region':region,'ip':public['ipAddress'],'hostname':public['dnsSettings']['fqdn'],'peer_id':peer_id,'addresses':addresses,'feed_token_sha256':hashlib.sha256(feed_token.encode()).hexdigest(),'registered':registration is not None,'installation':result})
        ARGS.receipt.write_text(json.dumps(receipt,indent=2)+'\n')
        print('INSTALLED',node,public['dnsSettings']['fqdn'],flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--subscription',required=True)
    parser.add_argument('--registry',required=True,type=label)
    parser.add_argument('--environment',default='staging',type=label)
    parser.add_argument('--generation',required=True,type=label)
    parser.add_argument('--built-sha',help='Reuse an already-built immutable relay image from this revision')
    parser.add_argument('--regions',nargs='+',default=['eastus','westus2'],type=label)
    parser.add_argument('--size',default='Standard_D2als_v7')
    parser.add_argument('--authority-keys',required=True,type=Path)
    parser.add_argument('--ssh-key',required=True,type=Path)
    parser.add_argument('--receipt',required=True,type=Path)
    parser.add_argument('--control-url', help='HTTPS v3 control service URL; registers relay feed credentials')
    parser.add_argument('--control-token-file', type=Path, help='Stack admin bearer used with --control-url')
    parser.add_argument('--control-team', default='transport-v3-ops', type=label)
    ARGS=parser.parse_args()
    if bool(ARGS.control_url) != bool(ARGS.control_token_file):
        parser.error('--control-url and --control-token-file must be supplied together')
    main()
