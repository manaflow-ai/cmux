import { shellQuote } from "./cmuxTuiDaemon";

export const SCP_KEY_TTL_SECONDS = 15 * 60;

/** Accept one Ed25519 key, not an authorized_keys options line or shell text. */
export function parseSshPublicKey(input: string): string {
  const match = /^ssh-ed25519 ([A-Za-z0-9+/]+={0,2})(?: [A-Za-z0-9_.@:-]+)?$/.exec(input.trim());
  const blob = match ? Buffer.from(match[1], "base64") : Buffer.alloc(0);
  if (blob.length !== 51 || blob.readUInt32BE(0) !== 11 ||
      blob.subarray(4, 15).toString() !== "ssh-ed25519" || blob.readUInt32BE(15) !== 32) {
    throw new Error("Expected one Ed25519 SSH public key.");
  }
  return `ssh-ed25519 ${blob.toString("base64")}`;
}

export function scpAuthorizedKeyLine(publicKey: string, expires: Date): string {
  const expiry = expires.toISOString().replace(/[-:]/g, "").replace("T", "").replace(/\.\d{3}Z$/, "Z");
  return `restrict,expiry-time="${expiry}" ${parseSshPublicKey(publicKey)} cmux-scp:${Math.floor(expires.getTime() / 1000)}`;
}

/** Run as cmux. Preserve unrelated keys and concurrent transfers under flock. */
export function scpAuthorizeCommand(publicKey: string, expires: Date): string {
  const line = scpAuthorizedKeyLine(publicKey, expires);
  return [
    "set -eu", "umask 077", 'mkdir -p "$HOME/.ssh"', 'cd "$HOME/.ssh"',
    "exec 9>.cmux-scp.lock", "flock -x 9", 'touch authorized_keys',
    'tmp=$(mktemp .cmux-scp.XXXXXXXXXX)', `trap 'rm -f -- "$tmp"' EXIT`,
    // Only our expired markers are removed. User and provider keys are preserved.
    `awk -v now="$(date +%s)" '{ if ($NF ~ /^cmux-scp:[0-9]+$/) { split($NF,a,":"); if (a[2] <= now) next } print }' authorized_keys > "$tmp"`,
    `printf '%s\\n' ${shellQuote(line)} >> "$tmp"`,
    'chmod 600 "$tmp"', 'mv -f -- "$tmp" authorized_keys',
  ].join("; ");
}

/** Read the host key over the authenticated provider API, never ssh-keyscan. */
export function scpPrepareCommand(publicKey: string, expires: Date): string {
  return [
    "set -eu", "test -x /usr/sbin/sshd", "systemctl start ssh",
    `runuser -u cmux -- sh -c ${shellQuote(scpAuthorizeCommand(publicKey, expires))}`,
    "cat /etc/ssh/ssh_host_ed25519_key.pub",
  ].join("; ");
}
