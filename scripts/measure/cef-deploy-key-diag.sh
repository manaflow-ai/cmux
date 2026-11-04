#!/usr/bin/env bash
# Read-only diagnostic (CEF 44 RELEASE, STATUS cmux-ad m7 1): why a cef job's
# `git ls-remote` of the private fork gets "Permission denied (publickey)" on a
# worker whose login shell reaches the fork with the same key. Prints the job's
# identity, PATH, which ssh/git it gets, the deploy key it is told to use, and a
# verbose ssh handshake to GitHub with that key. Changes nothing on the host.
#   cmux-ci run --class exclusive --script scripts/measure/cef-deploy-key-diag.sh \
#     --ref <sha> --target-worker <worker>
set -u
echo "== id: $(id)"
echo "== HOME=$HOME USER=${USER:-} LOGNAME=${LOGNAME:-}"
echo "== PATH=$PATH"
echo "== which ssh: $(command -v ssh)  which git: $(command -v git)"
ls -l "$(command -v ssh)" 2>&1
echo "== CMUX_CEF_DEPLOY_KEY=${CMUX_CEF_DEPLOY_KEY:-<unset>}"
echo "== GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-<unset>} GIT_SSH=${GIT_SSH:-<unset>} SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-<unset>}"
env | grep -E '^(GIT_|SSH_|CMUX_CEF_)' | sed -E 's/(TOKEN|SECRET|PASSWORD)=.*/\1=<hidden>/' | sort
key="${CMUX_CEF_DEPLOY_KEY:-/Users/ec2-user/.ssh/cmux-ci-cef-deploy_ed25519}"
echo "== key: $key"
ls -ld "$(dirname "$key")" 2>&1
ls -l "$key" "$key.pub" "$(dirname "$key")/known_hosts" 2>&1
[[ -r "$key" ]] && echo "key readable: yes" || echo "key readable: NO"
echo "== ssh -vvv -i $key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$(dirname "$key")/known_hosts -T git@github.com"
ssh -vvv -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$(dirname "$key")/known_hosts" -T git@github.com 2>&1
echo "== ssh exit $? (1 with 'successfully authenticated' = OK; 255 = failed)"
exit 0
