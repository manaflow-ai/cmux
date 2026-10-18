import { spawn } from "node:child_process";
import type { VmHostLeaseProviderClient } from "./hostLeaseTransport";
function safeLeasePart(value: string, name: string): string {
  if (!/^[A-Za-z0-9._:/-]{1,256}$/.test(value)) throw new Error(`${name} contains unsupported characters`);
  return value;
}

function b64(value: string): string {
  return Buffer.from(value, "utf8").toString("base64");
}

function runSsh(host: string, script: string, options: { readonly user?: string; readonly identityFile?: string; readonly proxyCommand?: string }): Promise<string> {
  return new Promise((resolve, reject) => {
    const args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new"];
    if (options.user) args.push("-o", `User=${safeLeasePart(options.user, "SSH user")}`);
    if (options.identityFile) args.push("-i", safeLeasePart(options.identityFile, "SSH key path"));
    if (options.proxyCommand) args.push("-o", `ProxyCommand=${options.proxyCommand}`);
    args.push(host, "bash", "-s");
    const child = spawn("ssh", args, { stdio: ["pipe", "pipe", "pipe"] });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) return resolve(Buffer.concat(stdout).toString("utf8"));
      reject(new Error(`host lease SSH transport failed with exit ${code}: ${Buffer.concat(stderr).toString("utf8").slice(0, 512)}`));
    });
    child.stdin.end(script);
  });
}

export function createSshHostLeaseClient(host: string, options: { readonly user?: string; readonly identityFile?: string; readonly proxyCommand?: string }): VmHostLeaseProviderClient {
  const safeHost = safeLeasePart(host, "SSH host");
  return {
    acquire: (input) => runSshLease(safeHost, options, input),
    renew: (input) => runSshLease(safeHost, options, input),
    release: (input) => runSshLease(safeHost, options, input),
  };
}

async function runSshLease(
  host: string,
  options: { readonly user?: string; readonly identityFile?: string; readonly proxyCommand?: string },
  input: Parameters<VmHostLeaseProviderClient["acquire"]>[0],
): Promise<{ providerLeaseId: string; expiresAtMs: number; generation: number; metadata: Record<string, unknown> }> {
  const leaseId = safeLeasePart(input.leaseId, "lease id");
  const ownerId = safeLeasePart(input.ownerId, "owner id");
  const effectKey = safeLeasePart(input.effectKey, "effect key");
  const hostId = safeLeasePart(input.hostId, "host id");
  const op = input.operation;
  const script = `
set -eu
root="\$HOME/.cache/cmux-agent-broker/leases"
mkdir -p "\$root"
exec 9>"\$root/.lock"
flock -x 9
lease_id=\$(printf '%s' '${b64(leaseId)}' | base64 -d)
owner_id=\$(printf '%s' '${b64(ownerId)}' | base64 -d)
effect_key=\$(printf '%s' '${b64(effectKey)}' | base64 -d)
host_id=\$(printf '%s' '${b64(hostId)}' | base64 -d)
path="\$root/\$lease_id"
now_ms=${input.nowMs}
generation=${input.generation}
ttl_ms=${input.ttlMs}
current_owner=''
current_generation=0
current_expiry=0
if [ -f "\$path" ]; then read -r current_owner current_generation current_expiry _current_effect _current_host < "\$path" || true; fi
if [ '${op}' = acquire ]; then
  if [ "\$current_expiry" -gt "\$now_ms" ] && [ "\$generation" -le "\$current_generation" ]; then exit 73; fi
  expiry=\$((now_ms + ttl_ms))
  printf '%s %s %s %s %s\\n' "\$owner_id" "\$generation" "\$expiry" "\$effect_key" "\$host_id" > "\$path.tmp"
  mv -f "\$path.tmp" "\$path"
elif [ "\$current_owner" != "\$owner_id" ] || [ "\$current_generation" -ne "\$generation" ] || [ "\$current_expiry" -le "\$now_ms" ]; then
  exit 74
elif [ '${op}' = renew ]; then
  expiry=\$((now_ms + ttl_ms))
  printf '%s %s %s %s %s\\n' "\$owner_id" "\$generation" "\$expiry" "\$effect_key" "\$host_id" > "\$path.tmp"
  mv -f "\$path.tmp" "\$path"
else
  expiry=\$now_ms
  rm -f "\$path"
fi
printf '{"providerLeaseId":"ssh-%s","expiresAtMs":%s,"generation":%s,"metadata":{"transport":"ssh","hostId":"%s"}}\\n' "\$lease_id" "\$expiry" "\$generation" "\$host_id"
`;
  const parsed = JSON.parse((await runSsh(host, script, options)).trim()) as Record<string, unknown>;
  return {
    providerLeaseId: String(parsed.providerLeaseId),
    expiresAtMs: Number(parsed.expiresAtMs),
    generation: Number(parsed.generation),
    metadata: safeMetadata(parsed.metadata),
  };
}


function safeMetadata(value: unknown): Record<string, unknown> { return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {}; }
