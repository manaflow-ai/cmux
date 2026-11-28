#!/usr/bin/env bun
// Point the cmux VM image lock at one published cmux-tui build (the cloud agent template's
// cmux + acpmux, which are one binary), the first step of the nightly template bake (M1 of
// the 2026-10-18 Cloud plan, whose last copy is `99dea7b3734:PLAN.md`):
//   bun images/cmux-vm/pin-cmux-tui.ts --commit <40-hex> [--lock <path>] [--write]
//   bun images/cmux-vm/pin-cmux-tui.ts --latest [--write]
// Reads only files.cmux.com (the build's manifest.json for the sha256, a HEAD for the size). A
// feat-cmux-next commit with no manifest.json (MACHINE_BUILD) is pinned from its Cloud machine build
// under cmux-tui/<commit>/machine/ instead. It
// creates no VM and needs no key: the bake (cloud-vm-image-bake.yml) and promote.ts stay the
// only steps that spend Freestyle resources. Without --write it prints the planned change as JSON.
// With --write it rewrites the cmux-tui and cmux-tui-hook entries in place (the rest of the
// file keeps its bytes) and checks the result with the lock validator.
import { readFileSync, writeFileSync } from "node:fs";
import { DEFAULT_LOCK_PATH, parseInputsLock } from "../../web/scripts/cmux-vm-image/lock.ts";

const FILES = "https://files.cmux.com/cmux-tui";
// CMUX_TUI_FILES serves FILES from a local server in a test (web/tests/vm-image-pin-cmux-tui.test.ts); the lock
// still names the files.cmux.com URLs.
const served = (url: string) => (process.env.CMUX_TUI_FILES ? url.replace(FILES, process.env.CMUX_TUI_FILES) : url);
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

/**
 * MACHINE_BUILD: feat-cmux-next's full builds write cmux-tui/<commit>/manifest.json only for the commit that owns a
 * new tree key, and most of those runs failed on 2026-11-27 (07:49-09:36Z). The Cloud machine channel
 * (cmux-machine-channel.yml) builds the same two musl programs on every tree change and writes them once to
 * cmux-tui/<commit>/machine/. From 02:41Z on 2026-11-27 no commit after the lock's f7b548a5 had a manifest, so
 * every push roll said "none of the 40 newest commits after the pin has a published build" while the channel moved
 * on, and the image lock fell 420 min behind (bound 120). A commit with no manifest is pinned from those files: the
 * sha256 is the signed channel's when it names the commit, otherwise the hash of the write-once bytes.
 *
 * One source line either way: the pin must write the same lock bytes whichever way it read the sha256. The roll
 * pins at bake start and again at promote, and approve (auto-roll.ts) compares the two locks' digests. A bake takes
 * ~45 min and the channel moves on to a newer commit meanwhile, so the bake's lock said "signed" and promote's said
 * "sha256 of the bytes": rolls 46085354594 and 46091967248 (2026-11-28) passed every gate and promoted nothing
 * ("the tip moved the image inputs since the bake"), with no input changed, and production's image fell 485 min behind.
 */
async function machinePins(commit: string): Promise<Pin[]> {
  const channel = await fetch(served(`${FILES}/channels/cloud-machine.json`), { signal: AbortSignal.timeout(30_000) })
    .then(async (r) => (r.ok ? ((await r.json()) as { payload?: string }) : {}))
    .catch(() => ({}) as { payload?: string });
  let named: Record<string, { sha256?: string; size?: number; url?: string }> = {};
  try {
    const payload = JSON.parse(Buffer.from(channel.payload ?? "", "base64").toString("utf8")) as {
      commit?: string;
      purpose?: string;
      targets?: Record<string, Record<string, { sha256?: string; size?: number; url?: string }>>;
    };
    if (payload.commit === commit && payload.purpose === "cmux-cloud-machine-update") named = payload.targets?.[TARGET] ?? {};
  } catch {
    named = {};
  }
  const pins: Pin[] = [];
  for (const name of PROGRAMS) {
    const url = `${FILES}/${commit}/machine/${name}-${TARGET}`;
    const head = await fetch(served(url), { method: "HEAD", signal: AbortSignal.timeout(30_000) });
    const size = Number(head.headers.get("content-length") ?? "");
    if (!head.ok || !Number.isSafeInteger(size) || size <= 0) throw new Error(`${url}: HEAD ${head.status}, no size`);
    let sha256 = named[name]?.url === url && named[name]?.size === size ? (named[name]?.sha256 ?? "") : "";
    if (!/^[0-9a-f]{64}$/.test(sha256)) {
      const body = await fetch(served(url), { signal: AbortSignal.timeout(300_000) });
      if (!body.ok || !body.body) throw new Error(`${url}: GET ${body.status}`);
      const hash = new Bun.CryptoHasher("sha256");
      let got = 0;
      for await (const chunk of body.body) {
        hash.update(chunk);
        got += chunk.byteLength;
      }
      if (got !== size) throw new Error(`${url}: read ${got} of ${size} bytes`);
      sha256 = hash.digest("hex");
    }
    const source = `${FILES}/${commit}/machine/ (the Cloud machine build, write-once; pinned by images/cmux-vm/pin-cmux-tui.ts)`;
    pins.push({ name, version: commit, url, sha256, size, source });
  }
  return pins;
}

const res = await fetch(served(manifestUrl), { signal: AbortSignal.timeout(30_000) });
let pins: Pin[] = [];
let commit = "";
if (res.status === 404 && !flag("--latest")) {
  commit = value("--commit") ?? "";
  pins = await machinePins(commit);
} else {
  if (!res.ok) throw new Error(`${manifestUrl}: ${res.status}`);
  const manifest = (await res.json()) as Manifest;
  commit = manifest.commit ?? "";
  if (!/^[0-9a-f]{40}$/.test(commit)) throw new Error(`${manifestUrl}: no commit`);
  for (const name of PROGRAMS) {
    const file = `${name}-${TARGET}`;
    const sha256 = manifest.binaries?.[file] ?? "";
    if (!/^[0-9a-f]{64}$/.test(sha256)) throw new Error(`build ${commit} publishes no ${file}`);
    const url = `${FILES}/${commit}/${file}`;
    const head = await fetch(served(url), { method: "HEAD", signal: AbortSignal.timeout(30_000) });
    const size = Number(head.headers.get("content-length") ?? "");
    if (!head.ok || !Number.isSafeInteger(size) || size <= 0) throw new Error(`${url}: HEAD ${head.status}, no size`);
    const source = `${FILES}/${commit}/manifest.json (${manifest.attestationUrl ?? "no attestation url"}; pinned by images/cmux-vm/pin-cmux-tui.ts)`;
    pins.push({ name, version: commit, url, sha256, size, source });
  }
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
