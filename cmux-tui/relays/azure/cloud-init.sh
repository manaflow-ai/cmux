#!/usr/bin/env bash
# This file is rendered by bicep/shard.bicep. Values with double underscores
# are deployment parameters, not runtime secrets.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --yes --no-install-recommends ca-certificates curl jq python3

install -d -m 0750 /etc/cmux-relay /usr/local/libexec
install -d -m 0750 /opt/cmux-relay

decode_parameter() {
  printf '%s' "$1" | base64 --decode
}

key_vault_name="$(decode_parameter '__CMUX_RELAY_KEY_VAULT_NAME_B64__')"
secret_name="$(decode_parameter '__CMUX_RELAY_SECRET_NAME_B64__')"
relay_binary_url="$(decode_parameter '__CMUX_RELAY_BINARY_URL_B64__')"
relay_binary_sha256="$(decode_parameter '__CMUX_RELAY_BINARY_SHA256_B64__')"
relay_shard="$(decode_parameter '__CMUX_RELAY_SHARD_B64__')"

if [[ ! "$key_vault_name" =~ ^[A-Za-z0-9-]{3,24}$ ]]; then
  echo 'cmux relay Key Vault name has unsupported characters' >&2
  exit 1
fi
if [[ ! "$secret_name" =~ ^[A-Za-z0-9-]{1,127}$ ]]; then
  echo 'cmux relay secret name has unsupported characters' >&2
  exit 1
fi
if [[ ! "$relay_shard" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  echo 'cmux relay shard has unsupported characters' >&2
  exit 1
fi
if [[ ! "$relay_binary_url" =~ ^https://files\.cmux\.com/cmux-relay/[0-9a-f]{40}/cmux-relay-x86_64-unknown-linux-musl$ ]]; then
  echo 'cmux-relay binary URL must be an immutable files.cmux.com x86_64 artifact' >&2
  exit 1
fi
if [[ ! "$relay_binary_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo 'cmux-relay binary SHA-256 must contain 64 lowercase hexadecimal characters' >&2
  exit 1
fi

export CMUX_RELAY_KEY_VAULT_NAME="$key_vault_name"
export CMUX_RELAY_SECRET_NAME="$secret_name"
export CMUX_RELAY_BINARY_URL="$relay_binary_url"
export CMUX_RELAY_BINARY_SHA256="$relay_binary_sha256"
export CMUX_RELAY_SHARD="$relay_shard"

binary_tmp="$(mktemp /tmp/cmux-relay.XXXXXX)"
trap 'rm -f "$binary_tmp"' EXIT
curl --proto '=https' --proto-redir '=https' --fail --silent --show-error \
  --retry 8 --retry-delay 2 --retry-max-time 120 --location \
  "$relay_binary_url" -o "$binary_tmp"
printf '%s  %s\n' "$relay_binary_sha256" "$binary_tmp" | sha256sum --check --status -
install -m 0755 "$binary_tmp" /opt/cmux-relay/cmux-relay
trap - EXIT
rm -f "$binary_tmp"

install -m 0750 /dev/null /usr/local/libexec/cmux-relay-load-secret
python3 - <<'PY'
import os
from pathlib import Path

path = Path('/usr/local/libexec/cmux-relay-load-secret')
template = r'''#!/usr/bin/env bash
set -euo pipefail

key_vault_name='__CMUX_RELAY_KEY_VAULT_NAME__'
secret_name='__CMUX_RELAY_SECRET_NAME__'
token_json="$(curl --fail --silent --show-error \
  --retry 5 --retry-delay 2 --retry-max-time 60 \
  -H 'Metadata: true' \
  'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net')"
access_token="$(printf '%s' "$token_json" | jq -er '.access_token')"
secret_uri="https://${key_vault_name}.vault.azure.net/secrets/${secret_name}?api-version=7.4"
secret_value="$(curl --fail --silent --show-error \
  --retry 5 --retry-delay 2 --retry-max-time 60 \
  -H "Authorization: Bearer ${access_token}" "$secret_uri" | jq -er '.value')"

if [[ -z "$secret_value" || "$secret_value" == *$'\n'* || "$secret_value" == *$'\r'* ]]; then
  echo 'cmux-relay secret is empty or contains a newline' >&2
  exit 1
fi

umask 077
printf 'CMUX_RELAY_HMAC_SECRET=%s\n' "$secret_value" > /run/cmux-relay.env
chmod 0600 /run/cmux-relay.env
''')
path.write_text(
    template
    .replace('__CMUX_RELAY_KEY_VAULT_NAME__', os.environ['CMUX_RELAY_KEY_VAULT_NAME'])
    .replace('__CMUX_RELAY_SECRET_NAME__', os.environ['CMUX_RELAY_SECRET_NAME'])
)
path.chmod(0o750)
PY

install -m 0750 /dev/null /usr/local/libexec/cmux-relay-run
python3 - <<'PY'
import os
from pathlib import Path

path = Path('/usr/local/libexec/cmux-relay-run')
template = r'''#!/usr/bin/env bash
set -euo pipefail

binary='/opt/cmux-relay/cmux-relay'
if [[ ! -x "$binary" ]]; then
  echo 'cmux-relay binary is missing or not executable' >&2
  exit 1
fi
secret="$(sed -n 's/^CMUX_RELAY_HMAC_SECRET=//p' /run/cmux-relay.env)"
if [[ -z "$secret" || "$secret" == *$'\n'* || "$secret" == *$'\r'* ]]; then
  echo 'cmux-relay runtime secret is missing or malformed' >&2
  exit 1
fi
export CMUX_RELAY_HMAC_SECRET="$secret"
export CMUX_RELAY_BIND='0.0.0.0:8787'
export CMUX_RELAY_ALLOW_OPEN='false'
export CMUX_RELAY_SHARD='__CMUX_RELAY_SHARD__'
export CMUX_RELAY_ISSUER='cmux-cloud-__CMUX_RELAY_SHARD__'
export CMUX_RELAY_DRAIN_TIMEOUT_SECONDS='300'
exec "$binary" serve "$@"
''')
path.write_text(
    template
    .replace('__CMUX_RELAY_SHARD__', os.environ['CMUX_RELAY_SHARD'])
)
path.chmod(0o750)
PY

cat > /etc/systemd/system/cmux-relay.service <<'UNIT'
[Unit]
Description=cmux encrypted circuit relay
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/local/libexec/cmux-relay-load-secret
ExecStart=/usr/local/libexec/cmux-relay-run
Restart=always
RestartSec=10s
TimeoutStartSec=120s
TimeoutStopSec=330s
KillMode=process

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable cmux-relay.service
# Do not make VM provisioning fail while the Key Vault role assignment is
# still propagating. The service retries its secret fetch on a ten-second
# restart interval.
systemctl start --no-block cmux-relay.service
