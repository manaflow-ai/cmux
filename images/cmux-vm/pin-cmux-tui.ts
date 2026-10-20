#!/usr/bin/env bun
// Point the cmux VM image lock at one published cmux-tui build (the cloud agent template's
// cmux + acpmux, which are one binary), the first step of the nightly template bake (PLAN.md M1):
//   bun images/cmux-vm/pin-cmux-tui.ts --commit <40-hex> [--lock <path>] [--write]
//   bun images/cmux-vm/pin-cmux-tui.ts --latest [--write]
// Reads only files.cmux.com (the build's manifest.json for the sha256, a HEAD for the size). It
// creates no VM and needs no key: the bake (cloud-vm-image-bake.yml) and promote.ts stay the
// only steps that spend Freestyle resources. Without --write it prints the planned change as JSON.
// With --write it rewrites the cmux-tui and cmux-tui-hook entries in place (the rest of the
// file keeps its bytes) and checks the result with the lock validator.
import { readFileSync, writeFileSync } from "node:fs";
import { DEFAULT_LOCK_PATH, parseInputsLock } from "../../web/scripts/cmux-vm-image/lock.ts";

const FILES = "https://files.cmux.com/cmux-tui";
const TARGET = "x86_64-unknown-linux-musl";
const PROGRAMS = ["cmux-tui", "cmux-tui-hook"] as const;

type Manifest = { commit?: string; attestationUrl?: string; binaries?: Record<string, string> };
type Pin = { name: string; version: string; url: string; sha256: string; size: number; source: string };

const argv = process.argv.slice(2);
const flag = (name: string) => argv.includes(name);
const value = (name: string) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};

const usage = "usage: pin-cmux-tui.ts --commit <40-hex> | --latest [--lock <path>] [--write]";
const lockPath = value("--lock") ?? DEFAULT_LOCK_PATH;
const manifestUrl = flag("--latest") ? `${FILES}/latest/manifest.json` : `${FILES}/${value("--commit") ?? ""}/manifest.json`;
if (!flag("--latest") && !/^[0-9a-f]{40}$/.test(value("--commit") ?? "")) throw new Error(usage);

const res = await fetch(manifestUrl, { signal: AbortSignal.timeout(30_000) });
if (!res.ok) throw new Error(`${manifestUrl}: ${res.status}`);
const manifest = (await res.json()) as Manifest;
const commit = manifest.commit ?? "";
if (!/^[0-9a-f]{40}$/.test(commit)) throw new Error(`${manifestUrl}: no commit`);

const pins: Pin[] = [];
for (const name of PROGRAMS) {
  const file = `${name}-${TARGET}`;
  const sha256 = manifest.binaries?.[file] ?? "";
  if (!/^[0-9a-f]{64}$/.test(sha256)) throw new Error(`build ${commit} publishes no ${file}`);
  const url = `${FILES}/${commit}/${file}`;
  const head = await fetch(url, { method: "HEAD", signal: AbortSignal.timeout(30_000) });
  const size = Number(head.headers.get("content-length") ?? "");
  if (!head.ok || !Number.isSafeInteger(size) || size <= 0) throw new Error(`${url}: HEAD ${head.status}, no size`);
  const source = `${FILES}/${commit}/manifest.json (${manifest.attestationUrl ?? "no attestation url"}; pinned by images/cmux-vm/pin-cmux-tui.ts)`;
  pins.push({ name, version: commit, url, sha256, size, source });
}

const before = readFileSync(lockPath, "utf8");
let after = before;
const changes: Array<{ name: string; from: { version: string; sha256: string; size: number }; to: Pin }> = [];
for (const pin of pins) {
  // One program entry: from its "name" line to the closing brace at the entry's indent.
  const start = after.indexOf(`"name": "${pin.name}",`);
  const end = start < 0 ? -1 : after.indexOf("\n    }", start);
  if (start < 0 || end < 0) throw new Error(`${lockPath}: no program entry ${pin.name}`);
  const block = after.slice(start, end);
  const old = parseInputsLock(before).programs.find((p) => p.name === pin.name);
  if (!old) throw new Error(`${lockPath}: no program ${pin.name}`);
  if (old.version === pin.version && old.sha256 === pin.sha256) continue;
  const next = block
    .replace(/"version": "[^"]*"/, `"version": "${pin.version}"`)
    .replace(/"url": "[^"]*"/, `"url": "${pin.url}"`)
    .replace(/"sha256": "[^"]*"/, `"sha256": "${pin.sha256}"`)
    .replace(/"size": \d+/, `"size": ${pin.size}`)
    .replace(/"source": "[^"]*"/, `"source": "${pin.source}"`);
  after = after.slice(0, start) + next + after.slice(end);
  changes.push({ name: pin.name, from: { version: old.version, sha256: old.sha256, size: old.size }, to: pin });
}

const lock = parseInputsLock(after);
for (const pin of pins) {
  const got = lock.programs.find((p) => p.name === pin.name);
  if (got?.sha256 !== pin.sha256 || got.size !== pin.size || got.url !== pin.url) throw new Error(`rewrite of ${pin.name} did not land`);
}

const unchanged = after === before;
console.log(JSON.stringify({ lock: lockPath, commit, unchanged, written: flag("--write") && !unchanged, changes }, null, 2));
if (flag("--write") && !unchanged) writeFileSync(lockPath, after);
