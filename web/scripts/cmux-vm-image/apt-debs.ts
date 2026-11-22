#!/usr/bin/env bun
/**
 * Write apt.ubuntu.debs in images/cmux-vm/inputs.lock.json: for every Ubuntu pin (apt.ubuntu.packages, the
 * first-use closures, devTree.apt), its .deb's pool path, sha256 and size from the lock's dated snapshot.
 * Run from web/ after changing a pin or the snapshot date:
 *   bun ../images/cmux-vm/apt-debs.ts [--lock <path>] [--check]
 * --check writes nothing and exits 1 when the lock's records differ from the snapshot's.
 *
 * The index is the snapshot's signed one: InRelease is checked with gpgv against the lock's keyring
 * (apt.ubuntu.signedBy, present on any Ubuntu host), and each Packages.xz against InRelease's SHA256.
 * The bake then fetches each file by these records and never reads an index (bake.ts installUbuntuDebs).
 * The indexes download in parallel: snapshot.ubuntu.com serves about 110 KB/s per connection.
 */
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { type AptDeb, DEFAULT_LOCK_PATH, parseInputsLock, ubuntuPins } from "./lock";

const ARCH = "amd64";

async function fetchBytes(url: string): Promise<Buffer> {
  for (let attempt = 1; ; attempt++) {
    try {
      const res = await fetch(url);
      if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
      return Buffer.from(await res.arrayBuffer());
    } catch (error) {
      if (attempt >= 3) throw error;
    }
  }
}

/** The Release text of a signed InRelease, or a thrown error when gpgv refuses it. */
function verifiedRelease(inRelease: Buffer, keyring: string, dir: string, suite: string): string {
  const signed = path.join(dir, `${suite}.InRelease`);
  const out = path.join(dir, `${suite}.Release`);
  writeFileSync(signed, inRelease);
  const gpgv = spawnSync("gpgv", ["--keyring", keyring, "--output", out, signed], { encoding: "utf8" });
  if (gpgv.status !== 0) throw new Error(`gpgv refused ${suite}/InRelease: ${gpgv.stderr}`);
  return readFileSync(out, "utf8");
}

/** Packages-file paragraphs -> `name=version` -> deb, for amd64 and all. */
export function parsePackages(text: string): Map<string, AptDeb> {
  const debs = new Map<string, AptDeb>();
  for (const para of text.split("\n\n")) {
    const field = (name: string) => para.match(new RegExp(`^${name}: (.*)$`, "m"))?.[1];
    const [pkg, version, arch, filename, sha256, size] = ["Package", "Version", "Architecture", "Filename", "SHA256", "Size"].map(field);
    if (!pkg || !version || !filename || !sha256 || !size || (arch !== ARCH && arch !== "all")) continue;
    debs.set(`${pkg}=${version}`, { path: filename, sha256, size: Number(size) });
  }
  return debs;
}

/** The lock's debs block, one pin per line, as the lock carries it. */
export function debsBlock(debs: ReadonlyMap<string, AptDeb>, indent = "      "): string {
  const lines = [...debs.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([pin, d]) => `${indent}  ${JSON.stringify(pin)}: { "path": ${JSON.stringify(d.path)}, "sha256": ${JSON.stringify(d.sha256)}, "size": ${d.size} }`);
  return `${indent}"debs": {\n${lines.join(",\n")}\n${indent}}`;
}

/** The lock text with its apt.ubuntu.debs block replaced (or added after apt.ubuntu.firstUse). */
export function withDebsBlock(lockText: string, block: string): string {
  const existing = /^ {6}"debs": \{\n[\s\S]*?\n {6}\}/m;
  if (existing.test(lockText)) return lockText.replace(existing, () => block);
  const firstUseEnd = /(^ {6}"firstUse": \{\n[\s\S]*?\n {6}\})(\n {4}\},\n {4}"pgdg")/m;
  if (!firstUseEnd.test(lockText)) throw new Error("cannot find apt.ubuntu.firstUse's end to add debs after");
  return lockText.replace(firstUseEnd, (_, firstUse: string, rest: string) => `${firstUse},\n${block}${rest}`);
}

export async function main(argv = process.argv): Promise<number> {
  const lockIndex = argv.indexOf("--lock");
  const lockPath = path.resolve(lockIndex >= 0 ? argv[lockIndex + 1]! : DEFAULT_LOCK_PATH);
  const check = argv.includes("--check");
  const text = readFileSync(lockPath, "utf8");
  const raw = JSON.parse(text);
  const ubuntu = raw.apt.ubuntu;
  const base = String(ubuntu.uri).replace(/\/?$/, "/");
  const pins = new Set(ubuntuPins(raw.apt, raw.devTree));
  const dir = mkdtempSync(path.join(tmpdir(), "apt-debs-"));
  const found = new Map<string, AptDeb>();
  try {
    for (const suite of ubuntu.suites as string[]) {
      const release = verifiedRelease(await fetchBytes(`${base}dists/${suite}/InRelease`), ubuntu.signedBy, dir, suite);
      const sha256Section = release.split(/^SHA256:$/m)[1] ?? "";
      const indexes = await Promise.all(
        (ubuntu.components as string[]).map(async (component) => {
          const rel = `${component}/binary-${ARCH}/Packages.xz`;
          const bytes = await fetchBytes(`${base}dists/${suite}/${rel}`);
          const sha = createHash("sha256").update(bytes).digest("hex");
          if (!new RegExp(`^ ${sha}\\s+${bytes.length} ${rel.replace(/[.+]/g, "\\$&")}$`, "m").test(sha256Section)) throw new Error(`${suite}/${rel}: sha256 is not the signed Release's`);
          const xz = spawnSync("xz", ["-dc"], { input: bytes, maxBuffer: 1 << 30 });
          if (xz.status !== 0) throw new Error(`${suite}/${rel}: xz failed`);
          return xz.stdout.toString("utf8");
        }),
      );
      for (const index of indexes) for (const [pin, deb] of parsePackages(index)) if (pins.has(pin)) found.set(pin, deb);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  const missing = [...pins].filter((pin) => !found.has(pin));
  if (missing.length > 0) {
    console.error(`snapshot ${ubuntu.snapshot} has no .deb for ${missing.length} pins: ${missing.join(", ")}`);
    return 1;
  }
  const updated = withDebsBlock(text, debsBlock(found));
  parseInputsLock(updated);
  if (check) {
    if (updated === text) return 0;
    console.error(`apt.ubuntu.debs differs from snapshot ${ubuntu.snapshot}; run bun ../images/cmux-vm/apt-debs.ts`);
    return 1;
  }
  if (updated !== text) writeFileSync(lockPath, updated);
  console.log(`apt.ubuntu.debs: ${found.size} pins from snapshot ${ubuntu.snapshot}${updated === text ? " (unchanged)" : ""}`);
  return 0;
}
