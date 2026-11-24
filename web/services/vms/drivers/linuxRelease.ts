// The signed Linux release file (cmuxterm-hq docs/design/linux-signed-packages.md section 2),
// read the way cmux-tui's `cmux-signed-envelope` crate reads it (linux_release.rs): the
// envelope `{"schema":1,"payload":"<base64>","signatures":[{"key_id","sig"}]}`, Ed25519 over
// the exact payload bytes, opened with keys compiled in here before any field is read. The
// Cloud image bake (path C) takes the build it installs from this file, never from the
// unsigned `manifest.json`.
//
// A file is held to the place it was read from: `<commit>/release.json` must name that
// commit, `tree/<key>/release.json` that tree, `channels/linux-<channel>.json` that channel
// (and must not have expired); and a binary's URL must be exactly `<prefix><name>-<target>`
// under the file's own prefix (`cmux-tui/<commit>/`, or `cmux-tui/tree/<tree_key>/` when the
// payload names its tree), so a payload cannot send the bake to another host or build.

import { createPublicKey, verify as verifySignature, type KeyObject } from "node:crypto";

export const LINUX_RELEASE_PURPOSE = "cmux-linux-release";
export const LINUX_RELEASE_FILES_PREFIX = "https://files.cmux.com/cmux-tui/";
/** A cmux-tui build is about 160 MB; nothing a release names is near this. */
export const LINUX_RELEASE_MAX_FILE_BYTES = 512 * 1024 * 1024;
/** A release file is a few kilobytes. */
export const LINUX_RELEASE_MAX_BYTES = 256 * 1024;

/**
 * The keys a Linux release file may be signed with: `[id, base64 raw Ed25519 key]`. Phase 1
 * of the design signs with the web update key, so this list equals
 * Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json and
 * cmux-tui's `linux_release::KEYS` (tests/vm-linux-release.test.ts and
 * cmux-tui/scripts/linux-release-verify-gen.py --check keep them equal). To
 * rotate, add the next key here and deploy it before CI signs with it.
 */
export const LINUX_RELEASE_KEYS: readonly (readonly [string, string])[] = [
  ["e5d7bbcacc70703d", "uroy2ajE6JWnMjkx3FNdn88SJN4DCMfLpqZjkwx45WY="],
];

export type LinuxReleaseKey = { readonly id: string; readonly key: KeyObject };

// DER SubjectPublicKeyInfo header of an Ed25519 key (RFC 8410); the raw 32 bytes follow it.
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

/** A raw 32-byte Ed25519 public key as a node:crypto key. */
export function linuxReleaseKey(id: string, raw: Uint8Array): LinuxReleaseKey {
  if (raw.length !== 32) throw new Error(`key ${id} is not a 32-byte Ed25519 key`);
  return { id, key: createPublicKey({ key: Buffer.concat([ED25519_SPKI_PREFIX, raw]), format: "der", type: "spki" }) };
}

/** [`LINUX_RELEASE_KEYS`], decoded. */
export function linuxReleaseTrustedKeys(): LinuxReleaseKey[] {
  return LINUX_RELEASE_KEYS.map(([id, b64]) => linuxReleaseKey(id, Buffer.from(b64, "base64")));
}

/** Where a release file was read from, and so what it must name. */
export type LinuxReleasePlace =
  /** `cmux-tui/<commit>/release.json`: the build's own file, or (phase 1b) a signed alias of its tree. */
  | { readonly commit: string }
  /** `cmux-tui/tree/<key>/release.json`: the tree's own file. */
  | { readonly tree: string }
  /** `cmux-tui/channels/linux-<channel>.json`: the channel's moving pointer. */
  | { readonly channel: string; readonly now?: Date };

export type LinuxReleaseFile = { readonly url: string; readonly sha256: string; readonly size: number };

export type LinuxRelease = {
  /** The commit that built it (for a tree's file, the commit that published the tree). */
  readonly commit: string;
  readonly treeKey: string | null;
  readonly version: string;
  /**
   * File `name` (`cmux-tui`, `cmux-tui-hook`, …) for Rust `target`, checked: its URL is
   * exactly `<prefix><name>-<target>`, its sha256 lowercase hex and its size in range. Null
   * when the release does not list it; a listed file that fails a check throws.
   */
  file(target: string, name: string): LinuxReleaseFile | null;
};

const HEX40 = /^[0-9a-f]{40}$/;
const HEX64 = /^[0-9a-f]{64}$/;

function record(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}

/** The payload bytes, when a `keys` signature covers them (cmux-signed-envelope `open`). */
export function openLinuxReleaseEnvelope(body: string | Uint8Array, keys: readonly LinuxReleaseKey[]): Buffer {
  const text = typeof body === "string" ? body : Buffer.from(body).toString("utf8");
  let envelope: Record<string, unknown> | null;
  try {
    envelope = record(JSON.parse(text));
  } catch {
    envelope = null;
  }
  if (!envelope || typeof envelope.payload !== "string" || !Array.isArray(envelope.signatures)) {
    throw new Error("the release file is not an envelope");
  }
  if (envelope.schema !== 1) throw new Error(`unknown envelope schema ${String(envelope.schema)}`);
  const payload = Buffer.from(envelope.payload, "base64");
  const signed = envelope.signatures.some((entry) => {
    const signature = record(entry);
    if (!signature || typeof signature.key_id !== "string" || typeof signature.sig !== "string") return false;
    const key = keys.find((candidate) => candidate.id === signature.key_id);
    if (!key) return false;
    try {
      return verifySignature(null, payload, key.key, Buffer.from(signature.sig, "base64"));
    } catch {
      return false;
    }
  });
  if (!signed) throw new Error("no valid signature by a trusted key");
  return payload;
}

function parsePayload(body: string | Uint8Array, keys: readonly LinuxReleaseKey[]): Record<string, unknown> {
  const length = typeof body === "string" ? Buffer.byteLength(body) : body.length;
  if (length > LINUX_RELEASE_MAX_BYTES) throw new Error(`the release file is ${length} bytes, over the limit`);
  const bytes = openLinuxReleaseEnvelope(body, keys);
  let payload: Record<string, unknown> | null = null;
  try {
    payload = record(JSON.parse(bytes.toString("utf8")));
  } catch {
    payload = null;
  }
  if (!payload) throw new Error("the release payload does not parse");
  if (payload.schema !== 1) throw new Error(`unknown release payload schema ${String(payload.schema)}`);
  if (payload.purpose !== LINUX_RELEASE_PURPOSE) {
    throw new Error(`the payload is a ${String(payload.purpose)} file, not a Linux release`);
  }
  return payload;
}

function treeKeyOf(payload: Record<string, unknown>): string | null {
  const treeKey = payload.tree_key;
  if (treeKey === undefined || treeKey === null) return null;
  if (typeof treeKey !== "string" || !HEX40.test(treeKey)) throw new Error("the release names a malformed tree key");
  return treeKey;
}

/** Throws unless the payload is the file of `place`. */
function checkPlace(payload: Record<string, unknown>, commit: string, treeKey: string | null, place: LinuxReleasePlace): void {
  if ("commit" in place) {
    if (commit !== place.commit) throw new Error(`the release file of ${place.commit} is for commit ${commit}`);
    return;
  }
  if ("tree" in place) {
    if (treeKey !== place.tree) throw new Error(`the release file of tree ${place.tree} is not that tree's`);
    return;
  }
  if (payload.channel !== place.channel) {
    throw new Error(`the ${place.channel} channel file is for channel ${String(payload.channel)}`);
  }
  const now = Math.floor((place.now ?? new Date()).getTime() / 1000);
  if (typeof payload.expires_at !== "number" || payload.expires_at <= now) {
    throw new Error(`the ${place.channel} channel file has expired`);
  }
}

function checkedFile(entry: Record<string, unknown>, url: string, label: string): LinuxReleaseFile {
  if (entry.url !== url) throw new Error(`${label}: the url is not ${url}`);
  if (typeof entry.sha256 !== "string" || !HEX64.test(entry.sha256)) throw new Error(`${label}: the sha256 is not a sha256`);
  const size = entry.size;
  if (typeof size !== "number" || !Number.isSafeInteger(size) || size <= 0 || size > LINUX_RELEASE_MAX_FILE_BYTES) {
    throw new Error(`${label}: size ${String(size)} is out of range`);
  }
  return { url, sha256: entry.sha256, size };
}

/** The release in `body`, read from `place`, when a `keys` signature covers it and it is a Linux release file of that place; throws why not. */
export function verifyLinuxRelease(
  body: string | Uint8Array,
  place: LinuxReleasePlace,
  keys: readonly LinuxReleaseKey[] = linuxReleaseTrustedKeys(),
): LinuxRelease {
  const payload = parsePayload(body, keys);
  const commit = typeof payload.commit === "string" ? payload.commit : "";
  if (!HEX40.test(commit)) throw new Error("the release names no commit");
  const treeKey = treeKeyOf(payload);
  const targets = record(payload.targets);
  if (!targets) throw new Error("the release lists no targets");
  checkPlace(payload, commit, treeKey, place);
  // A file that names its tree serves the tree's URLs; else the commit's own.
  const prefix = treeKey ? `${LINUX_RELEASE_FILES_PREFIX}tree/${treeKey}/` : `${LINUX_RELEASE_FILES_PREFIX}${commit}/`;
  return {
    commit,
    treeKey,
    version: typeof payload.version === "string" ? payload.version : "",
    file(target, name) {
      const entry = record(record(targets[target])?.[name]);
      return entry ? checkedFile(entry, `${prefix}${name}-${target}`, `${name}-${target}`) : null;
    },
  };
}
