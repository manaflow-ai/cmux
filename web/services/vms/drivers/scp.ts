import { createHash } from "node:crypto";
import { shellQuote } from "./cmuxTuiDaemon";

export const SCP_KEY_TTL_SECONDS = 15 * 60;
/** A rescue shell key only has to last until the client authenticates once. */
export const SHELL_KEY_TTL_SECONDS = 5 * 60;

/** At most this many unexpired rescue shell keys may sit on one machine. */
export const SHELL_KEY_LIVE_MAX = 8;

/**
 * Drops only our expired markers (`cmux-scp:<unix>`, `cmux-shell:<unix>`);
 * user and provider keys are preserved. Run with `awk -v now=<unix>`.
 */
export const GUEST_KEY_CLEANUP_AWK =
  '{ if ($NF ~ /^cmux-(scp|shell):[0-9]+$/) { split($NF,a,":"); if (a[2] <= now) next } print }';

/**
 * Shell text that fails when the file already holds SHELL_KEY_LIVE_MAX shell
 * keys. `fileWord` is a shell word (already quoted), for example `"$tmp"`.
 */
export function shellKeyCapCheck(fileWord: string): string {
  return `live=$(grep -c ' cmux-shell:[0-9][0-9]*$' ${fileWord} || true); ` +
    `if [ "$live" -ge ${SHELL_KEY_LIVE_MAX} ]; then echo "too many live cmux shell keys" >&2; exit 3; fi`;
}

type GuestKeyKind = "scp" | "shell";

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

/** OpenSSH-style SHA256 fingerprint, for audit records (never log the key). */
export function sshKeyFingerprint(publicKey: string): string {
  const blob = Buffer.from(parseSshPublicKey(publicKey).split(" ")[1], "base64");
  return `SHA256:${createHash("sha256").update(blob).digest("base64").replace(/=+$/, "")}`;
}

function guestKeyLine(kind: GuestKeyKind, publicKey: string, expires: Date): string {
  const expiry = expires.toISOString().replace(/[-:]/g, "").replace("T", "").replace(/\.\d{3}Z$/, "Z");
  // `restrict` turns off port, agent and X11 forwarding, user rc and PTYs; a
  // shell key turns only the PTY back on.
  const options = kind === "shell" ? `restrict,pty,expiry-time="${expiry}"` : `restrict,expiry-time="${expiry}"`;
  return `${options} ${parseSshPublicKey(publicKey)} cmux-${kind}:${Math.floor(expires.getTime() / 1000)}`;
}

export function scpAuthorizedKeyLine(publicKey: string, expires: Date): string {
  return guestKeyLine("scp", publicKey, expires);
}

export function shellAuthorizedKeyLine(publicKey: string, expires: Date): string {
  return guestKeyLine("shell", publicKey, expires);
}

/** Run as cmux. Preserve unrelated keys and concurrent transfers under flock. */
export function scpAuthorizeCommand(publicKey: string, expires: Date): string {
  return guestKeyAuthorizeCommand(scpAuthorizedKeyLine(publicKey, expires), false);
}

export function shellAuthorizeCommand(publicKey: string, expires: Date): string {
  return guestKeyAuthorizeCommand(shellAuthorizedKeyLine(publicKey, expires), true);
}

function guestKeyAuthorizeCommand(line: string, capShellKeys: boolean): string {
  return [
    "set -eu", "umask 077", 'mkdir -p "$HOME/.ssh"', 'cd "$HOME/.ssh"',
    "exec 9>.cmux-scp.lock", "flock -x 9", 'touch authorized_keys',
    'tmp=$(mktemp .cmux-scp.XXXXXXXXXX)', `trap 'rm -f -- "$tmp"' EXIT`,
    `awk -v now="$(date +%s)" ${shellQuote(GUEST_KEY_CLEANUP_AWK)} authorized_keys > "$tmp"`,
    ...(capShellKeys ? [shellKeyCapCheck('"$tmp"')] : []),
    `printf '%s\\n' ${shellQuote(line)} >> "$tmp"`,
    'chmod 600 "$tmp"', 'mv -f -- "$tmp" authorized_keys',
  ].join("; ");
}

/** Read the host key over the authenticated provider API, never ssh-keyscan. */
export function scpPrepareCommand(publicKey: string, expires: Date): string {
  return guestKeyPrepareCommand(scpAuthorizeCommand(publicKey, expires));
}

export function shellPrepareCommand(publicKey: string, expires: Date): string {
  return guestKeyPrepareCommand(shellAuthorizeCommand(publicKey, expires));
}

function guestKeyPrepareCommand(authorize: string): string {
  return [
    "set -eu", "test -x /usr/sbin/sshd", "systemctl start ssh",
    `runuser -u cmux -- sh -c ${shellQuote(authorize)}`,
    "cat /etc/ssh/ssh_host_ed25519_key.pub",
  ].join("; ");
}
