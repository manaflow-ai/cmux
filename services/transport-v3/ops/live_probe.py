#!/usr/bin/env python3
"""Run live relay tests remotely, signing only test permissions on the operator machine."""
import argparse,base64,json,os,select,subprocess,tempfile,time
from pathlib import Path

def b64(data): return base64.urlsafe_b64encode(data).rstrip(b'=')
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--relay',required=True);p.add_argument('--ssh',required=True);p.add_argument('--binary',required=True)
    p.add_argument('--seed',required=True,type=Path);p.add_argument('--public-keys',required=True,type=Path);p.add_argument('--key-id',required=True)
    p.add_argument('--receipt',required=True,type=Path)
    args=p.parse_args()
    import shlex
    proc=subprocess.Popen(['ssh','-o','BatchMode=yes',args.ssh,shlex.quote(args.binary)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
    try:
        if not select.select([proc.stdout],[],[],20)[0]: raise RuntimeError('probe identity timeout')
        peers=json.loads(proc.stdout.readline());stamp=int(time.time())
        seed=args.seed.read_bytes()
        if len(seed)!=32 or args.seed.stat().st_mode&0o077: raise ValueError('seed must be a private 32-byte file')
        with tempfile.TemporaryDirectory() as directory:
            key=Path(directory)/'key.der';key.write_bytes(bytes.fromhex('302e020100300506032b657004220420')+seed);key.chmod(0o600)
            def grant(source,destination,action):
                claims={'iss':'cmux-transport-v3','aud':destination,'sub':source,'team_id':'v3-staging-e2e','action':action,'policy_revision':1,
                        'lease':{'offline':{'mode':'bounded','seconds':300},'renew_every_seconds':30},'iat':stamp,'exp':stamp+300}
                message=b64(json.dumps({'alg':'EdDSA','typ':'cmux-v3-grant+jwt','kid':args.key_id},separators=(',',':')).encode())+b'.'+b64(json.dumps(claims,separators=(',',':')).encode())
                msg=Path(directory)/'message';msg.write_bytes(message)
                sig=subprocess.check_output(['openssl','pkeyutl','-sign','-rawin','-inkey',str(key),'-keyform','DER','-in',str(msg)])
                return (message+b'.'+b64(sig)).decode()
            request={'relay':args.relay,'team':'v3-staging-e2e','keys':json.loads(args.public_keys.read_text()),
                     'reserve':grant(peers['destination'],args.relay.rsplit('/p2p/',1)[1],'relay_reserve'),
                     'connect':grant(peers['source'],peers['destination'],'connect')}
            proc.stdin.write(json.dumps(request)+'\n');proc.stdin.flush()
            # No signing key is ever transmitted, only short-lived test permissions.
            if not select.select([proc.stdout],[],[],100)[0]: raise RuntimeError('live relay timeout')
            result=json.loads(proc.stdout.readline())
            if not result.get('passed') or proc.wait(timeout=10)!=0: raise RuntimeError('live relay test failed')
            args.receipt.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
    finally:
        if proc.poll() is None: proc.terminate();proc.wait(timeout=10)
if __name__=='__main__': main()
