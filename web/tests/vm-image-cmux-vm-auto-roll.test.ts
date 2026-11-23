import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  AUTO_PREFIX,
  BOOT_ENTRY,
  KEEP_AUTO,
  LARGE_BOUNDS,
  MIN_AUTO,
  largeImageOn,
  probeEnv,
  rollNotes,
  workerReadsLarge,
  type Dropped,
  MAX_BYTES,
  MAX_ROLLS_BEHIND,
  ROLLBACK_DEPLOYS,
  approve,
  bootDrift,
  fallbackImage,
  withFallback,
  bootedImage,
  locate,
  modeOf,
  replaceList,
  rollback,
  rolledImage,
  settle,
  type BootImage,
  type SettleInput,
  platformPins,
} from "../../images/cmux-vm/auto-roll";
import { runChild, runChildOk } from "./helpers/run-child";

// images/cmux-vm/auto-roll.ts edits the checked-in workers/cmux-vm/wrangler.jsonc; these run on that file with its
// auto-rolled entries taken out, since the live roll keeps adding them and the counts below assume none.
const checkedIn = readFileSync(new URL("../../workers/cmux-vm/wrangler.jsonc", import.meta.url), "utf8");
const handOnly = (text: string, env: "staging" | "production") =>
  replaceList(text, env, locate(text, env).images.filter((i) => !i.id.startsWith(AUTO_PREFIX)));
const FALLBACK = fallbackImage();
/** The lists without cmux-platform's fallback entry: what the checked-in file was before a roll first wrote it. */
const withoutFallback = (text: string) =>
  (["staging", "production"] as const).reduce((t, env) => replaceList(t, env, locate(t, env).images.filter((i) => i.id !== FALLBACK.id)), text);
/** The hand-approved lists as a roll leaves them: the fallback entry included (approve writes it when missing). */
const wrangler = (["staging", "production"] as const).reduce(
  (t, env) => replaceList(t, env, withFallback(locate(t, env).images, env)),
  handOnly(handOnly(checkedIn, "staging"), "production"),
);
const candidate = { snapshot_id: `sh-${"a".repeat(32)}`, lock_sha256: "0".repeat(64), run: 1 };
const tui = "1234567890abcdef1234567890abcdef12345678";
const entry = (run: string, attempt = "1"): BootImage => rolledImage(candidate, `ci-${run}-${attempt}`, tui, run, attempt);
const KEY = "c".repeat(64);
/** The candidate's `large` member as cloud-vm-image-bake.yml writes it once large-smoke.ts passed on that snapshot. */
const LARGE_CANDIDATE = { snapshot: "img-large", snapshot_id: `sh-${"b".repeat(32)}`, size: { vcpu: 4, mem_gib: 16, disk_gib: 64 }, smoke: { result: "PASSED" } };
/** What the Worker reads on the entry: the large snapshot and the size a VM booted from it has. */
const LARGE_ENTRY = { snapshotId: `sh-${"b".repeat(32)}`, vcpus: 4, memoryMib: 16384, diskMib: 65536 };
/** This repository's Worker, and its list parser when it loads here (its dependencies are installed). */
const REAL_WORKER = new URL("../../workers/cmux-vm", import.meta.url).pathname;
type WorkerParse = (raw: string) => { ok: boolean; images: ReadonlyArray<{ large?: unknown }> };
const realWorker: { loaded: boolean; parse?: WorkerParse; readsLarge: boolean } = await (async () => {
  try {
    const source: string = `${REAL_WORKER}/src/upstream/live-images.ts`;
    const parse = ((await import(source)) as { parseVmImages: WorkerParse }).parseVmImages;
    const parsed = parse(JSON.stringify([{ id: "probe", revision: "r1", displayName: "Probe", snapshotId: "sh-probe", services: ["probe"], large: LARGE_ENTRY }]));
    return { loaded: true, parse, readsLarge: parsed.ok && parsed.images[0]?.large !== undefined };
  } catch {
    return { loaded: false, readsLarge: false };
  }
})();
/** A roll whose candidate records the inputs key and a smoked large image, with the roll's large switch on. */
const sized = (run: string): BootImage => rolledImage({ ...candidate, inputs_sha256: KEY, large: LARGE_CANDIDATE }, `ci-${run}-1`, tui, run, "1", { large: true });
/** A roll whose candidate records the image's inputs key (bake.ts bakeInputsSha256). */
const keyed = (run: string): BootImage => rolledImage({ ...candidate, inputs_sha256: KEY }, `ci-${run}-1`, tui, run, "1");

/** The file with every VM_BOOT_IMAGES value cut out, to show nothing else moved. */
const skeleton = (text: string) => text.replace(/"VM_BOOT_IMAGES": "(?:[^"\\\n]|\\.)*"/gu, '"VM_BOOT_IMAGES": ""');

describe("auto-roll approve", () => {
  test("puts the image first in production and last in staging, with each environment's services", () => {
    const before = { prod: locate(wrangler, "production").images, staging: locate(wrangler, "staging").images };
    const { text, previousFirst } = approve(wrangler, entry("100"));
    const prod = locate(text, "production").images;
    const staging = locate(text, "staging").images;
    expect(previousFirst).toBe(before.prod[0]!.id);
    expect(prod[0]).toEqual({ ...entry("100"), services: ["cloud-platform-production", "ci-product-smoke"] });
    expect(prod.slice(1)).toEqual(before.prod);
    expect(staging.at(-1)).toEqual({ ...entry("100"), services: ["cloud-platform-dev", "cloud-platform-staging"] });
    expect(staging.slice(0, -1)).toEqual(before.staging);
    expect(skeleton(text)).toBe(skeleton(wrangler));
    expect(prod[0]!.id).toBe(`${AUTO_PREFIX}12345678-100-1`);
  });

  test("keeps only the newest auto-rolled entries and never trims a hand-approved one", () => {
    let text = wrangler;
    for (let run = 1; run <= KEEP_AUTO + 3; run++) text = approve(text, entry(String(run))).text;
    const prod = locate(text, "production").images;
    const staging = locate(text, "staging").images;
    const autoIds = (list: BootImage[]) => list.filter((i) => i.id.startsWith(AUTO_PREFIX)).map((i) => i.id);
    const newest = Array.from({ length: KEEP_AUTO }, (_, i) => `${AUTO_PREFIX}12345678-${KEEP_AUTO + 3 - i}-1`);
    expect(autoIds(prod)).toEqual(newest);
    expect(autoIds(staging)).toEqual([...newest].reverse());
    const hand = (list: BootImage[]) => list.filter((i) => !i.id.startsWith(AUTO_PREFIX));
    expect(hand(prod)).toEqual(locate(wrangler, "production").images);
    expect(hand(staging)).toEqual(locate(wrangler, "staging").images);
  });

  // cmuxterm-hq probe cloud-chat-replies-staging 2026-11-17T14:03:17Z: a create that booted cmux-platform's pin got
  // cloud-native-bd31f93-rd022, the newest image every list kept. Its cmux-host ran the session host binary as the relay
  // ticket command (fixed by #37770) and its updater refused the channel's machine/ URLs (#42308), so the machine
  // never connected. An auto-rolled image leaves the lists within KEEP_AUTO rolls, so the pin needs a current entry
  // that every roll keeps.
  test("every roll keeps cmux-platform's fallback image listed in both lists, never where an environment boots", () => {
    expect(FALLBACK.id.startsWith(AUTO_PREFIX)).toBe(false);
    let text = withoutFallback(wrangler);
    for (let run = 1; run <= KEEP_AUTO + 3; run++) text = approve(text, entry(String(600 + run))).text;
    text = rollback(text, entry(String(600 + KEEP_AUTO + 3)).id).text;
    for (const env of ["staging", "production"] as const) {
      const images = locate(text, env).images;
      expect(images.filter((i) => i.id === FALLBACK.id)).toEqual([
        { ...FALLBACK, services: env === "production" ? ["cloud-platform-production", "ci-product-smoke"] : ["cloud-platform-dev", "cloud-platform-staging"] },
      ]);
      expect(bootedImage(text, env)).toBe(entry(String(600 + KEEP_AUTO + 2)).id);
    }
    expect(bootDrift(text).every((d) => d.ok)).toBe(true);
  });

  test("refuses an id that is already approved", () => {
    const { text } = approve(wrangler, entry("7"));
    expect(() => approve(text, entry("7"))).toThrow(/already approved/);
  });

  test("a re-run of the roll run (a new attempt) approves its own image instead of colliding", () => {
    const first = approve(wrangler, entry("9", "1")).text;
    const rerun = approve(first, entry("9", "2"));
    const prod = locate(rerun.text, "production").images;
    expect(prod[0]!.id).toBe(`${AUTO_PREFIX}12345678-9-2`);
    expect(prod[1]!.id).toBe(`${AUTO_PREFIX}12345678-9-1`);
    expect(rerun.previousFirst).toBe(`${AUTO_PREFIX}12345678-9-1`);
  });

  test("refuses a list the Worker would reject (more than 32 entries)", () => {
    const prod = locate(wrangler, "production").images;
    // Short entries, so 32 of them stay under MAX_BYTES and the entry cap is what refuses the 33rd.
    const many = Array.from({ length: 32 }, (_, i) => ({ ...prod[0]!, id: `h-${i}`, displayName: "h", services: ["s"] }));
    const big = wrangler.replace(/("production": \{[\s\S]*?"VM_BOOT_IMAGES": )("(?:[^"\\\n]|\\.)*")/u, (_, head: string) => head + JSON.stringify(JSON.stringify(many)));
    expect(() => approve(big, entry("8"))).toThrow(/at most 32/);
  });

  test("refuses a list over Cloudflare's text binding limit, which fails the whole deploy", () => {
    const staging = locate(wrangler, "staging").images;
    // Long hand-approved names push staging past MAX_BYTES while it stays under 32 entries.
    const name = "x".repeat(100);
    const many = Array.from({ length: 24 }, (_, i) => ({ ...staging[0]!, id: `hand-${i}`, displayName: name }));
    expect(Buffer.byteLength(JSON.stringify(many))).toBeGreaterThan(MAX_BYTES);
    const big = wrangler.replace(/("staging": \{[\s\S]*?"VM_BOOT_IMAGES": )("(?:[^"\\\n]|\\.)*")/u, (_, head: string) => head + JSON.stringify(JSON.stringify(many)));
    expect(() => approve(big, entry("8"))).toThrow(/bytes, at most 5120/);
    // A list deployed before a trim still reads, so settle can roll that deploy back.
    expect(locate(big, "staging").images).toHaveLength(24);
  });

  test("the checked-in lists, plus one more roll, stay under the text binding limit", () => {
    const { text } = approve(checkedIn, entry("9000"));
    for (const env of ["staging", "production"] as const)
      expect(Buffer.byteLength(JSON.stringify(locate(text, env).images))).toBeLessThanOrEqual(MAX_BYTES);
  });

  test("the hand-approved lists with every kept roll carrying inputs_sha256 stay under the text binding limit", () => {
    let text = checkedIn;
    for (let run = 1; run <= KEEP_AUTO; run++) text = approve(text, keyed(String(9100 + run))).text;
    for (const env of ["staging", "production"] as const) {
      const images = locate(text, env).images;
      expect(images.filter((i) => i.id.startsWith(AUTO_PREFIX)).every((i) => i.inputs_sha256 === KEY)).toBe(true);
      expect(Buffer.byteLength(JSON.stringify(images))).toBeLessThanOrEqual(MAX_BYTES);
    }
  });

  test("entries with and without inputs_sha256 share a list; a malformed one is refused", () => {
    const { text } = approve(approve(wrangler, entry("10")).text, keyed("11"));
    const prod = locate(text, "production").images;
    expect(prod[0]).toEqual({ ...keyed("11"), services: ["cloud-platform-production", "ci-product-smoke"] });
    expect(prod[1]).not.toHaveProperty("inputs_sha256");
    const bad = { ...keyed("12"), inputs_sha256: "A".repeat(64) };
    expect(() => replaceList(text, "production", [bad, ...prod])).toThrow(/bad inputs_sha256/);
    expect(() => replaceList(text, "production", [{ ...entry("12"), extra: "x" } as BootImage, ...prod])).toThrow(/fields/);
  });
});

// The large image (web/scripts/cmux-vm-image/large-image.ts): a second snapshot of the same bake, at the size a
// default Cloud chat start asks for. The Worker boots it for a create that asks for exactly that size.
describe("auto-roll large image", () => {
  const autos = (list: BootImage[]) => list.filter((i) => i.id.startsWith(AUTO_PREFIX));
  /** The Worker deployed with the list reads `large` (workerReadsLarge said so). */
  const READS = { workerReadsLarge: true };
  /** The same, with the roll's large switch on: a roll that would not fit the binding drops the oldest rolls. */
  const TRIM = { workerReadsLarge: true, trimToFit: true };
  const bytes =(list: BootImage[]) => Buffer.byteLength(JSON.stringify(list));

  test("the entry carries the candidate's large image, in the Worker's units, only with the switch on", () => {
    expect(sized("1")).toEqual({ ...keyed("1"), large: LARGE_ENTRY });
    // Switch off (auto-roll.json large_image: false), or no option at all: today's entry.
    const off = rolledImage({ ...candidate, inputs_sha256: KEY, large: LARGE_CANDIDATE }, "ci-1-1", tui, "1", "1", { large: false });
    expect(off).toEqual(keyed("1"));
    expect(rolledImage({ ...candidate, inputs_sha256: KEY, large: LARGE_CANDIDATE }, "ci-1-1", tui, "1", "1")).toEqual(keyed("1"));
    // Switch on and a candidate without one (the bake made none, or its smoke failed): today's entry.
    expect(rolledImage({ ...candidate, inputs_sha256: KEY }, "ci-1-1", tui, "1", "1", { large: true })).toEqual(keyed("1"));
  });

  test("a large image the Worker would drop, or one that was not smoked, is left out and the image still rolls", () => {
    const bad: unknown[] = [
      { ...LARGE_CANDIDATE, snapshot_id: candidate.snapshot_id }, // the image's own snapshot
      { ...LARGE_CANDIDATE, snapshot_id: "" },
      { ...LARGE_CANDIDATE, snapshot_id: "snap large" },
      { ...LARGE_CANDIDATE, smoke: { result: "FAILED" } },
      { ...LARGE_CANDIDATE, smoke: undefined },
      { ...LARGE_CANDIDATE, size: undefined },
      { ...LARGE_CANDIDATE, size: { vcpu: 1, mem_gib: 16, disk_gib: 64 } },
      { ...LARGE_CANDIDATE, size: { vcpu: 64, mem_gib: 16, disk_gib: 64 } },
      { ...LARGE_CANDIDATE, size: { vcpu: 4, mem_gib: 2, disk_gib: 64 } },
      { ...LARGE_CANDIDATE, size: { vcpu: 4, mem_gib: 128, disk_gib: 64 } },
      { ...LARGE_CANDIDATE, size: { vcpu: 4, mem_gib: 16, disk_gib: 8 } },
      { ...LARGE_CANDIDATE, size: { vcpu: 4, mem_gib: 16, disk_gib: 256 } },
      { ...LARGE_CANDIDATE, size: { vcpu: 4.5, mem_gib: 16, disk_gib: 64 } },
      { ...LARGE_CANDIDATE, size: { vcpu: "4", mem_gib: 16, disk_gib: 64 } },
      "sh-large",
      null,
    ];
    for (const large of bad)
      expect(rolledImage({ ...candidate, inputs_sha256: KEY, large: large as typeof LARGE_CANDIDATE }, "ci-1-1", tui, "1", "1", { large: true })).toEqual(keyed("1"));
  });

  test("approve writes the large image on that revision's entry in both lists", () => {
    const { text } = approve(wrangler, sized("100"), READS);
    const prod = locate(text, "production").images;
    const staging = locate(text, "staging").images;
    expect(prod[0]).toEqual({ ...keyed("100"), large: LARGE_ENTRY, services: ["cloud-platform-production", "ci-product-smoke"] });
    expect(staging.at(-1)).toEqual({ ...keyed("100"), large: LARGE_ENTRY, services: ["cloud-platform-dev", "cloud-platform-staging"] });
    expect(prod.slice(1)).toEqual(locate(wrangler, "production").images);
    expect(staging.slice(0, -1)).toEqual(locate(wrangler, "staging").images);
    expect(skeleton(text)).toBe(skeleton(wrangler));
  });

  // A retry of a create in flight boots the snapshot its first attempt was journaled from, so a published
  // revision's entry never gains or loses `large`: later rolls and another image's rollback pass it through.
  test("a published revision keeps its large image, and one published without it never gains one", () => {
    let text = approve(wrangler, entry("201")).text;
    text = approve(text, sized("202"), READS).text;
    // A later roll without a large image, by a roll that does not ask whether the Worker reads one.
    text = approve(text, keyed("203")).text;
    text = approve(text, sized("204"), READS).text;
    // A rollback never asks either: it only takes an entry out.
    text = rollback(text, keyed("203").id).text;
    for (const env of ["staging", "production"] as const) {
      const byId = new Map(locate(text, env).images.map((i) => [i.id, i]));
      expect(byId.get(sized("202").id)!.large).toEqual(LARGE_ENTRY);
      expect(byId.get(sized("204").id)!.large).toEqual(LARGE_ENTRY);
      expect(byId.get(entry("201").id)).not.toHaveProperty("large");
      expect(byId.has(keyed("203").id)).toBe(false);
    }
    expect(bootDrift(text).every((d) => d.ok)).toBe(true);
    // A rollback takes the pair out as one entry: the entry before it boots again, its own large image with it.
    const back = rollback(text, sized("204").id);
    expect(bootedImage(back.text, "production")).toBe(sized("202").id);
    expect(locate(back.text, "production").images[0]!.large).toEqual(LARGE_ENTRY);
  });

  test("a write that drops, replaces or adds the large image of a published revision is refused", () => {
    let text = approve(wrangler, entry("211")).text;
    text = approve(text, sized("212"), READS).text;
    for (const env of ["staging", "production"] as const) {
      const images = locate(text, env).images;
      const rewrite = (id: string, change: (i: BootImage) => BootImage) => images.map((i) => (i.id === id ? change(i) : i));
      const dropped = rewrite(sized("212").id, ({ large: _large, ...rest }) => rest);
      const replaced = rewrite(sized("212").id, (i) => ({ ...i, large: { ...LARGE_ENTRY, snapshotId: `sh-${"d".repeat(32)}` } }));
      const resized = rewrite(sized("212").id, (i) => ({ ...i, large: { ...LARGE_ENTRY, vcpus: 8 } }));
      const added = rewrite(entry("211").id, (i) => ({ ...i, large: LARGE_ENTRY }));
      for (const list of [dropped, replaced, resized, added]) {
        expect(() => replaceList(text, env, list, READS)).toThrow(/already published/);
        expect(() => replaceList(text, env, list)).toThrow(/already published/);
      }
      // The same list, and the list without that revision at all (a rollback or a trim), are written.
      expect(locate(replaceList(text, env, images), env).images).toEqual(images);
      const without = images.filter((i) => i.id !== sized("212").id);
      expect(locate(replaceList(text, env, without), env).images).toEqual(without);
    }
  });

  // Until the Worker's list schema names `large`, it refuses the whole list for one unknown entry field and every
  // approved image is disabled (src/upstream/live-images.ts, onExcessProperty: "error").
  test("a list that would newly carry a large image is refused unless the Worker deployed with it reads `large`", () => {
    for (const options of [undefined, {}, { workerReadsLarge: false }]) {
      expect(() => approve(wrangler, sized("220"), options)).toThrow(/would disable every image/);
      for (const env of ["staging", "production"] as const) {
        const images = locate(wrangler, env).images;
        const services = images[0]!.services;
        expect(() => replaceList(wrangler, env, [...images, { ...sized("220"), services }], options)).toThrow(/would disable every image/);
        // The same roll without its large image is written as it is today.
        expect(locate(replaceList(wrangler, env, [...images, { ...keyed("220"), services }], options), env).images.at(-1)!.id).toBe(keyed("220").id);
      }
    }
    expect(locate(approve(wrangler, sized("220"), READS).text, "production").images[0]!.large).toEqual(LARGE_ENTRY);
  });

  test("whether the Worker reads `large` is asked of its own list parser, and anything else is a no", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "auto-roll-worker-"));
    try {
      const worker = (name: string, source: string | undefined) => {
        const root = path.join(dir, name);
        mkdirSync(path.join(root, "src/upstream"), { recursive: true });
        if (source !== undefined) writeFileSync(path.join(root, "src/upstream/live-images.ts"), source);
        return root;
      };
      // Today's Worker: one unknown entry field and the whole list is invalid.
      const strict = `export const parseVmImages = (raw: string) => {
        const list = JSON.parse(raw) as Array<Record<string, unknown>>;
        return list.some((e) => "large" in e) ? { ok: false, images: [] } : { ok: true, images: list };
      };`;
      const reads = `export const parseVmImages = (raw: string) => ({ ok: true, images: JSON.parse(raw) });`;
      // A Worker that tolerates the field and drops it would boot the small image and resize: nothing to publish for.
      const drops = `export const parseVmImages = (raw: string) => ({ ok: true, images: (JSON.parse(raw) as Array<Record<string, unknown>>).map(({ large: _l, ...e }) => e) });`;
      expect(await workerReadsLarge(worker("strict", strict))).toBe(false);
      expect(await workerReadsLarge(worker("reads", reads))).toBe(true);
      expect(await workerReadsLarge(worker("drops", drops))).toBe(false);
      expect(await workerReadsLarge(worker("throws", `export const parseVmImages = () => { throw new Error("no"); };`))).toBe(false);
      expect(await workerReadsLarge(worker("other", `export const somethingElse = 1;`))).toBe(false);
      expect(await workerReadsLarge(worker("broken", `import "./not-there";`))).toBe(false);
      expect(await workerReadsLarge(worker("empty", undefined))).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("the lists check passes a large image only beside a Worker that reads it", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "auto-roll-lists-"));
    try {
      const script = new URL("../../images/cmux-vm/auto-roll.ts", import.meta.url).pathname;
      const file = path.join(dir, "wrangler.jsonc");
      mkdirSync(path.join(dir, "src/upstream"), { recursive: true });
      const parser = path.join(dir, "src/upstream/live-images.ts");
      const lists = () => runChild("bun", [script, "lists", "--wrangler", file]);
      // No large image anywhere: the check does not need the Worker.
      writeFileSync(file, approve(wrangler, keyed("230")).text);
      expect((await lists()).status).toBe(0);
      writeFileSync(file, approve(wrangler, sized("230"), READS).text);
      const refused = await lists();
      expect(refused.status).toBe(1);
      expect(refused.stderr).toMatch(/would disable every image/);
      // The Worker's parser reverted to one from before the field, beside a list that already carries it: every
      // image would be disabled at the next deploy, so the check that runs before every deploy fails.
      writeFileSync(parser, `export const parseVmImages = (raw: string) => (raw.includes('"large"') ? { ok: false, images: [] } : { ok: true, images: JSON.parse(raw) });`);
      const strict = await lists();
      expect(strict.status).toBe(1);
      expect(strict.stderr).toMatch(/would disable every image/);
      expect(strict.stderr).toContain(sized("230").id);
      writeFileSync(parser, `export const parseVmImages = (raw: string) => ({ ok: true, images: JSON.parse(raw) });`);
      const ok = await lists();
      expect(ok.status).toBe(0);
      expect(ok.stdout).toMatch(/staging VM_BOOT_IMAGES: \d+ bytes/);
      expect(ok.stdout).toMatch(/production VM_BOOT_IMAGES: \d+ bytes/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a list is refused when an entry's large image is one the Worker would drop", () => {
    const text = wrangler;
    const prod = locate(text, "production").images;
    const fresh = { ...keyed("300"), services: ["cloud-platform-production", "ci-product-smoke"] };
    const withLarge = (large: unknown) => [{ ...fresh, large } as BootImage, ...prod];
    for (const large of [
      { ...LARGE_ENTRY, extra: 1 },
      { snapshotId: LARGE_ENTRY.snapshotId, vcpus: 4, memoryMib: 16384 },
      { ...LARGE_ENTRY, snapshotId: fresh.snapshotId },
      { ...LARGE_ENTRY, snapshotId: "" },
      { ...LARGE_ENTRY, vcpus: 1 },
      { ...LARGE_ENTRY, vcpus: 33 },
      { ...LARGE_ENTRY, memoryMib: 4095 },
      { ...LARGE_ENTRY, memoryMib: 65537 },
      { ...LARGE_ENTRY, diskMib: 16383 },
      { ...LARGE_ENTRY, diskMib: 131073 },
      { ...LARGE_ENTRY, vcpus: 4.5 },
      { ...LARGE_ENTRY, vcpus: "4" },
      "sh-large",
      null,
    ])
      expect(() => replaceList(text, "production", withLarge(large), READS)).toThrow(/bad large/);
    // The Worker's bounds, both ends: 2-32 vCPU, 4,096-65,536 MiB of memory, 16,384-131,072 MiB of disk.
    for (const large of [{ ...LARGE_ENTRY, vcpus: 32, memoryMib: 65536, diskMib: 131072 }, { ...LARGE_ENTRY, vcpus: 2, memoryMib: 4096, diskMib: 16384 }])
      expect(locate(replaceList(text, "production", withLarge(large), READS), "production").images[0]!.large).toEqual(large);
    // A deployed commit's list still reads whatever Worker sits beside this checkout, so settle can roll it back.
    expect(locate(approve(wrangler, sized("301"), READS).text, "production").images[0]!.large).toEqual(LARGE_ENTRY);
  });

  // Measured on the checked-in lists (2026-11-18): staging 4,915 bytes with 6 rolls, production 4,353. A large image
  // is 105 bytes on its entry; on all 6 kept rolls staging would be 5,545, over the 5,120-byte binding limit that
  // fails the whole deploy. So a roll that would not fit drops the oldest rolls first, never below MIN_AUTO.
  test("rolls that all carry a large image stay within the binding limit by dropping the oldest rolls, never a hand-approved entry", () => {
    let text = checkedIn;
    const dropped: Dropped[] = [];
    for (let run = 1; run <= KEEP_AUTO + 2; run++) {
      const before = { staging: locate(text, "staging").images, production: locate(text, "production").images };
      const rolled = approve(text, sized(String(9200 + run)), TRIM);
      text = rolled.text;
      for (const env of ["staging", "production"] as const) {
        const after = locate(text, env).images;
        expect(bytes(after)).toBeLessThanOrEqual(MAX_BYTES);
        // Every roll the byte trim took out is named, with its revision and the reason: exactly the entries that
        // left beyond the KEEP_AUTO count trim, and nothing leaves unnamed.
        const gone = autos(before[env]).filter((i) => !after.some((a) => a.id === i.id));
        const byCount = Math.max(0, autos(before[env]).length + 1 - KEEP_AUTO);
        const named = rolled.dropped.filter((d) => d.env === env);
        expect(gone.length).toBe(byCount + named.length);
        expect(new Set(named.map((d) => d.id)).size).toBe(named.length);
        for (const d of named) {
          expect(gone.find((i) => i.id === d.id)!.revision).toBe(d.revision);
          expect(d.why).toMatch(/over the 5120-byte binding limit/);
        }
      }
      dropped.push(...rolled.dropped);
    }
    // Staging dropped rolls for the limit; production, which fits KEEP_AUTO rolls with a large image, dropped none.
    expect(dropped.some((d) => d.env === "staging")).toBe(true);
    expect(dropped.filter((d) => d.env === "production")).toEqual([]);
    const hand = (list: BootImage[]) => list.filter((i) => !i.id.startsWith(AUTO_PREFIX));
    for (const env of ["staging", "production"] as const) {
      const images = locate(text, env).images;
      const kept = autos(images);
      expect(kept.every((i) => i.large !== undefined)).toBe(true);
      expect(kept.length).toBeGreaterThanOrEqual(MIN_AUTO);
      expect(kept.length).toBeLessThanOrEqual(KEEP_AUTO);
      // The kept rolls are the newest ones, in the list's order, and the newest still boots.
      const newest = Array.from({ length: kept.length }, (_, i) => sized(String(9200 + KEEP_AUTO + 2 - i)).id);
      expect(kept.map((i) => i.id)).toEqual(env === "production" ? newest : [...newest].reverse());
      expect(bootedImage(text, env)).toBe(sized(String(9200 + KEEP_AUTO + 2)).id);
      expect(hand(images)).toEqual(hand(withFallback(locate(checkedIn, env).images, env)));
      // No more is dropped than the limit needs: one more of the dropped size would not have fit.
      if (kept.length < KEEP_AUTO) expect(bytes(images) + bytes([kept[0]!]) - 1).toBeGreaterThan(MAX_BYTES);
    }
    expect(bootDrift(text).every((d) => d.ok && d.behind === 0)).toBe(true);
  });

  test("the byte trim never goes below MIN_AUTO rolls: a list that still does not fit is refused", () => {
    expect(MIN_AUTO).toBeGreaterThanOrEqual(MAX_ROLLS_BEHIND + 2);
    const staging = locate(wrangler, "staging").images;
    const filler = (n: number) => Array.from({ length: n }, (_, i) => ({ ...staging[0]!, id: `hand-${i}`, displayName: "x".repeat(100) }));
    const withStaging = (list: BootImage[]) =>
      wrangler.replace(/("staging": \{[\s\S]*?"VM_BOOT_IMAGES": )("(?:[^"\\\n]|\\.)*")/u, (_, head: string) => head + JSON.stringify(JSON.stringify(list)));
    // Hand-approved entries that leave room for MIN_AUTO rolls with a large image, and not for one more.
    const services = ["cloud-platform-dev", "cloud-platform-staging"];
    const fits = (count: number) =>
      bytes([...filler(count), { ...FALLBACK, services }, ...Array.from({ length: MIN_AUTO }, (_, i) => ({ ...sized(String(9301 + i)), services }))]) <= MAX_BYTES;
    let n = 0;
    while (fits(n + 1)) n++;
    expect(n).toBeGreaterThan(0);
    let text = withStaging(filler(n));
    for (let run = 1; run <= MIN_AUTO + 2; run++) text = approve(text, sized(String(9300 + run)), TRIM).text;
    expect(autos(locate(text, "staging").images).map((i) => i.id)).toEqual(Array.from({ length: MIN_AUTO }, (_, i) => sized(String(9300 + 3 + i)).id));
    expect(autos(locate(text, "production").images)).toHaveLength(Math.min(KEEP_AUTO, MIN_AUTO + 2));
    // One hand-approved entry more: MIN_AUTO rolls no longer fit, and the roll is refused rather than trimmed further.
    let tight = withStaging(filler(n + 1));
    expect(() => {
      for (let run = 1; run <= MIN_AUTO; run++) tight = approve(tight, sized(String(9400 + run)), TRIM).text;
    }).toThrow(/bytes, at most 5120/);
  });

  // The byte trim belongs to the large image. With the switch off a list over the limit is what it was before:
  // a refused roll that someone sees, never rolled revisions quietly withdrawn (a hand-approved entry was added).
  test("without the large switch an over-limit list is refused, with nothing dropped", () => {
    const staging = locate(wrangler, "staging").images;
    const filler = (n: number) => Array.from({ length: n }, (_, i) => ({ ...staging[0]!, id: `hand-${i}`, displayName: "x".repeat(100) }));
    const withStaging = (list: BootImage[]) =>
      wrangler.replace(/("staging": \{[\s\S]*?"VM_BOOT_IMAGES": )("(?:[^"\\\n]|\\.)*")/u, (_, head: string) => head + JSON.stringify(JSON.stringify(list)));
    // Room for KEEP_AUTO - 1 rolls and not for KEEP_AUTO: the roll that would be the last kept one is over.
    const services = ["cloud-platform-dev", "cloud-platform-staging"];
    const fits = (count: number, rolls: number) =>
      bytes([...filler(count), { ...FALLBACK, services }, ...Array.from({ length: rolls }, (_, i) => ({ ...keyed(String(9501 + i)), services }))]) <= MAX_BYTES;
    let n = 0;
    while (fits(n + 1, KEEP_AUTO - 1)) n++;
    expect(fits(n, KEEP_AUTO)).toBe(false);
    let text = withStaging(filler(n));
    for (let run = 1; run < KEEP_AUTO; run++) {
      const rolled = approve(text, keyed(String(9500 + run)));
      expect(rolled.dropped).toEqual([]);
      text = rolled.text;
    }
    for (const options of [undefined, {}, { trimToFit: false }, READS])
      expect(() => approve(text, keyed(String(9500 + KEEP_AUTO)), options)).toThrow(/bytes, at most 5120/);
    // The same roll with the switch on fits by dropping the oldest roll, and says so.
    const trimmed = approve(text, keyed(String(9500 + KEEP_AUTO)), TRIM);
    expect(trimmed.dropped).toEqual([{ env: "staging", id: keyed("9501").id, revision: keyed("9501").revision, why: expect.stringContaining("over the 5120-byte binding limit") }]);
    expect(autos(locate(trimmed.text, "staging").images).map((i) => i.id)).not.toContain(keyed("9501").id);
  });

  // cmux-platform boots its pinned image before its isolate reads a list (platformPins); a pin a list no longer
  // names fails creates as cloud.provider.image_withdrawn. The byte trim holds to that as the count trim does.
  test("the byte trim never drops an image cmux-platform pins, and drops the next oldest roll instead", () => {
    const pinned = sized("9701");
    let text = approve(checkedIn, pinned, TRIM).text;
    const dropped: Dropped[] = [];
    for (let run = 2; run <= KEEP_AUTO + 3; run++) {
      const rolled = approve(text, sized(String(9700 + run)), { ...TRIM, keep: [pinned.id] });
      dropped.push(...rolled.dropped);
      text = rolled.text;
    }
    // The trim ran (staging cannot hold KEEP_AUTO rolls that all carry a large image), and never took the pin.
    expect(dropped.length).toBeGreaterThan(0);
    expect(dropped.map((d) => d.id)).not.toContain(pinned.id);
    for (const env of ["staging", "production"] as const) {
      const list = locate(text, env).images;
      expect({ env, pinned: list.filter((i) => i.id === pinned.id).length }).toEqual({ env, pinned: 1 });
      expect(bytes(list)).toBeLessThanOrEqual(MAX_BYTES);
    }
  });

  test("the roll's notes name every dropped roll and a large snapshot that was baked and not published", () => {
    const withLarge = { ...candidate, large: LARGE_CANDIDATE };
    const drop: Dropped = { env: "staging", id: keyed("9601").id, revision: "ci-9601-1", why: "the list was 5225 bytes, over the 5120-byte binding limit" };
    const published = { image: { id: "x", large: LARGE_ENTRY }, dropped: [] };
    // Published with its revision: nothing to say.
    expect(rollNotes(withLarge, published, "pushed")).toEqual([]);
    expect(rollNotes(candidate, { image: { id: "x", large: null }, dropped: [] }, "pushed")).toEqual([]);
    // Approve left it out (switch off, a Worker that does not read it, a large image the Worker would drop), the tip
    // moved (nothing), a dry run, or a promotion that failed before approve wrote anything.
    const cases: Array<[Parameters<typeof rollNotes>[1], string]> = [
      [{ image: { id: "x", large: null }, dropped: [] }, "pushed"],
      [published, "nothing"],
      [published, "dry-run"],
      [undefined, ""],
    ];
    for (const [approved, result] of cases) {
      const notes = rollNotes(withLarge, approved, result);
      expect(notes).toHaveLength(1);
      expect(notes[0]).toContain(LARGE_CANDIDATE.snapshot);
      expect(notes[0]).toContain(LARGE_CANDIDATE.snapshot_id);
      expect(notes[0]).toMatch(/not published/);
    }
    // A dropped roll is named with its list, revision and reason, when the commit that dropped it was made.
    const notes = rollNotes(candidate, { image: { id: "x", large: null }, dropped: [drop] }, "pushed");
    expect(notes).toHaveLength(1);
    for (const part of ["staging", drop.id, drop.revision, drop.why]) expect(notes[0]).toContain(part);
    expect(rollNotes(candidate, { image: { id: "x", large: null }, dropped: [drop] }, "nothing")).toEqual([]);
  });

  test("the notes command prints them for the job summary", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "auto-roll-notes-"));
    try {
      const script = new URL("../../images/cmux-vm/auto-roll.ts", import.meta.url).pathname;
      writeFileSync(path.join(dir, "candidate.json"), JSON.stringify({ ...candidate, large: LARGE_CANDIDATE }));
      writeFileSync(path.join(dir, "approve.json"), JSON.stringify({ image: { id: "x", large: null }, dropped: [] }));
      const unpublished = await runChild("bun", [script, "notes", "--candidate", path.join(dir, "candidate.json"), "--approve", path.join(dir, "approve.json"), "--result", "pushed"]);
      expect(unpublished.status).toBe(0);
      expect(unpublished.stdout).toContain(LARGE_CANDIDATE.snapshot);
      // No approve.json (approve never ran, or failed before it wrote one): still said.
      const none = await runChild("bun", [script, "notes", "--candidate", path.join(dir, "candidate.json"), "--result", ""]);
      expect(none.status).toBe(0);
      expect(none.stdout).toContain(LARGE_CANDIDATE.snapshot);
      writeFileSync(path.join(dir, "approve.json"), JSON.stringify({ image: { id: "x", large: LARGE_ENTRY }, dropped: [] }));
      const quiet = await runChild("bun", [script, "notes", "--candidate", path.join(dir, "candidate.json"), "--approve", path.join(dir, "approve.json"), "--result", "pushed"]);
      expect(quiet.status).toBe(0);
      expect(quiet.stdout.trim()).toBe("");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // The Worker's parser and its dependencies are third-party code to the roll. The promote job's push step holds
  // the tokens that push to feat-cmux-next (and start the production deploy) and to cmux-platform.
  test("the Worker is asked in a child process that has none of the caller's tokens, and any child failure is a no", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "auto-roll-probe-env-"));
    const secret = ["TOKEN", "PLATFORM_TOKEN", "GH_TOKEN", "GITHUB_TOKEN", "FREESTYLE_API_KEY", "CLOUDFLARE_API_TOKEN", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "CMUX_UITEST_STACK_PASSWORD"];
    const saved = Object.fromEntries(secret.map((name) => [name, process.env[name]]));
    try {
      for (const name of secret) process.env[name] = `secret-${name}`;
      const worker = (name: string, body: string) => {
        const root = path.join(dir, name);
        mkdirSync(path.join(root, "src/upstream"), { recursive: true });
        writeFileSync(path.join(root, "src/upstream/live-images.ts"), body);
        return root;
      };
      // A parser that records the environment it runs in, then reads `large`.
      const spy = worker("spy", `import { writeFileSync } from "node:fs";
        writeFileSync(new URL("./env.json", import.meta.url), JSON.stringify(process.env));
        export const parseVmImages = (raw: string) => ({ ok: true, images: JSON.parse(raw) });`);
      expect(await workerReadsLarge(spy)).toBe(true);
      const seen = JSON.parse(readFileSync(path.join(spy, "src/upstream/env.json"), "utf8")) as Record<string, string>;
      for (const name of secret) expect(seen).not.toHaveProperty(name);
      expect(Object.keys(seen).filter((name) => /TOKEN|SECRET|PASSWORD|API_KEY|^GIT_CONFIG_|^GITHUB_|^ACTIONS_/u.test(name))).toEqual([]);
      expect(JSON.stringify(seen)).not.toContain("secret-");
      expect(Object.keys(probeEnv({ ...process.env, PATH: "/bin", HOME: "/h" })).sort()).toEqual(expect.arrayContaining(["HOME", "PATH"]));
      // A parser that would say yes and then dies, hangs up the process or prints something else: still a no.
      expect(await workerReadsLarge(worker("exits", `export const parseVmImages = (raw: string) => { process.exit(0); };`))).toBe(false);
      expect(await workerReadsLarge(worker("crashes", `process.exit(3); export const parseVmImages = (raw: string) => ({ ok: true, images: JSON.parse(raw) });`))).toBe(false);
      expect(await workerReadsLarge(worker("chatty", `console.log(JSON.stringify({ reads: true })); export const parseVmImages = () => ({ ok: false, images: [] });`))).toBe(false);
    } finally {
      for (const name of secret) {
        if (saved[name] === undefined) delete process.env[name];
        else process.env[name] = saved[name];
      }
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // Contract with the Worker in this repository (workers/cmux-vm/src/upstream/live-images.ts). On this base its Entry
  // schema has no `large` and refuses the whole list for the unknown field, so the answer is no and the roll writes
  // none. When https://github.com/manaflow-ai/cmux/pull/47035 lands, the same call answers yes wherever the Worker's
  // dependencies are installed (cmux-vm.yml's check, the roll's plan and promote jobs) and stays no where they are
  // not (this suite's runner): the roll then leaves `large` out rather than guess.
  test("the repository's Worker is asked for real, and the roll's answer is that parser's", async () => {
    const answer = await workerReadsLarge(REAL_WORKER);
    expect(answer).toBe(realWorker.readsLarge);
    if (!realWorker.loaded) expect(answer).toBe(false);
    // The roll's own decision follows it: beside a Worker that does not read `large`, a list with one is refused.
    if (!answer) expect(() => approve(wrangler, sized("240"), { workerReadsLarge: answer })).toThrow(/would disable every image/);
  });

  // Skipped until the Worker's schema names `large` (and its dependencies are installed to load it): there is no
  // schema to pin to on this base. LARGE_BOUNDS then has to be exactly what the Worker keeps and drops.
  (realWorker.readsLarge ? test : test.skip)("LARGE_BOUNDS are the Worker's: it keeps a large image at each bound and drops one just outside", () => {
    const parse = realWorker.parse!;
    const probe = (large: Record<string, unknown>) =>
      parse(JSON.stringify([{ id: "probe", revision: "r1", displayName: "Probe", snapshotId: "sh-probe", services: ["probe"], large }]));
    for (const axis of ["vcpus", "memoryMib", "diskMib"] as const) {
      const [min, max] = LARGE_BOUNDS[axis];
      for (const kept of [min, max]) expect(probe({ ...LARGE_ENTRY, [axis]: kept }).images[0]!.large).toEqual({ ...LARGE_ENTRY, [axis]: kept });
      for (const out of [min - 1, max + 1, min + 0.5]) {
        const parsed = probe({ ...LARGE_ENTRY, [axis]: out });
        expect(parsed.ok).toBe(true);
        expect(parsed.images[0]).not.toHaveProperty("large");
      }
    }
    // The other two things the roll refuses on `large`: an unknown field, and the entry's own snapshot.
    expect(probe({ ...LARGE_ENTRY, extra: 1 }).images[0]).not.toHaveProperty("large");
    expect(probe({ ...LARGE_ENTRY, snapshotId: "sh-probe" }).images[0]).not.toHaveProperty("large");
  });

  test("the roll's large switch is off unless auto-roll.json says large_image: true", () => {
    expect(largeImageOn('{"mode":"live"}')).toBe(false);
    expect(largeImageOn('{"mode":"live","large_image":false}')).toBe(false);
    expect(largeImageOn('{"mode":"live","large_image":true}')).toBe(true);
    expect(() => largeImageOn('{"mode":"live","large_image":"true"}')).toThrow(/large_image/);
    expect(typeof largeImageOn(readFileSync(new URL("../../images/cmux-vm/auto-roll.json", import.meta.url), "utf8"))).toBe("boolean");
  });
});

// Production, 2026-11-20 19:44Z: cmux-platform pinned CLOUD_VM_API_IMAGE to cloud-native-auto-9d5f6bd6-44156090531-1,
// a roll trimmed it from every list (KEEP_AUTO), and a create that booted the pin answered
// cloud.provider.image_withdrawn. The roll reads cmux-platform's pins and never takes one out of a list.
describe("auto-roll keeps cmux-platform's pinned image", () => {
  const platform = [
    '{ "env": {',
    '  "development": { "vars": { "CLOUD_VM_API_IMAGE": "PIN" } },',
    '  // a comment, as in the real file',
    '  "staging": { "vars": { "CLOUD_VM_API_IMAGE": "PIN", "CLOUD_VM_API_IMAGE_REVISION": "ci-1-1" } },',
    '  "production": { "vars": { "CLOUD_VM_API_IMAGE": "OTHER" } } } }',
  ].join("\n");
  test("platformPins reads every environment's CLOUD_VM_API_IMAGE, once each", () => {
    expect(platformPins(platform.replaceAll("PIN", "a").replaceAll("OTHER", "b"))).toEqual(["a", "b"]);
    expect(platformPins("{}")).toEqual([]);
  });
  test("approve never trims a pinned auto-rolled image, however many rolls follow it", () => {
    const pinned = entry("500");
    let text = approve(wrangler, pinned).text;
    for (let run = 1; run <= KEEP_AUTO + 3; run++) text = approve(text, entry(String(500 + run)), { keep: [pinned.id] }).text;
    for (const env of ["staging", "production"] as const) {
      expect({ env, pinned: locate(text, env).images.filter((i) => i.id === pinned.id).length }).toEqual({ env, pinned: 1 });
      // The pin does not count toward KEEP_AUTO: the newest KEEP_AUTO rolls stay too.
      expect({ env, auto: locate(text, env).images.filter((i) => i.id.startsWith(AUTO_PREFIX)).length }).toEqual({ env, auto: KEEP_AUTO + 1 });
    }
  });
  test("rollback refuses to take out a pinned image", () => {
    const pinned = entry("550");
    const text = approve(approve(wrangler, pinned).text, entry("551")).text;
    const result = rollback(text, pinned.id, [pinned.id]);
    expect(result.rolledBack).toBe(false);
    expect(result.reason).toContain("cmux-platform pins");
    expect(result.text).toBe(text);
  });
});

describe("auto-roll check (stale boot image detector)", () => {
  const drift = (text: string) => Object.fromEntries(bootDrift(text).map((d) => [d.env, d]));

  test("each environment boots the entry cmux-platform follows: production its first, staging its last", () => {
    expect(BOOT_ENTRY).toEqual({ production: "first", staging: "last" });
    const { text } = approve(wrangler, entry("700"));
    expect(bootedImage(text, "production")).toBe(entry("700").id);
    expect(bootedImage(text, "staging")).toBe(entry("700").id);
    expect(bootDrift(text).every((d) => d.ok && d.behind === 0)).toBe(true);
  });

  test("a roll, several rolls and a rollback keep both environments on production's newest roll", () => {
    let text = wrangler;
    for (let run = 1; run <= KEEP_AUTO + 2; run++) text = approve(text, entry(String(800 + run))).text;
    expect(bootDrift(text).map((d) => d.behind)).toEqual([0, 0]);
    text = rollback(text, entry(String(800 + KEEP_AUTO + 2)).id).text;
    expect(bootDrift(text).map((d) => d.behind)).toEqual([0, 0]);
  });

  test("fails when staging's boot entry trails production's newest roll by more than MAX_ROLLS_BEHIND", () => {
    let text = wrangler;
    for (let run = 1; run <= MAX_ROLLS_BEHIND + 2; run++) text = approve(text, entry(String(900 + run))).text;
    // A staging list that stopped taking rolls: its newest roll(s) dropped, the older ones still last.
    const staging = locate(text, "staging").images;
    const stale = replaceList(text, "staging", staging.slice(0, -(MAX_ROLLS_BEHIND + 1)));
    const d = drift(stale);
    expect(d.production!.ok).toBe(true);
    expect(d.staging!.ok).toBe(false);
    expect(d.staging!.behind).toBe(MAX_ROLLS_BEHIND + 1);
    // Reordered newest-first like production: staging would boot its oldest entry, a hand-approved image.
    const reordered = replaceList(text, "staging", [...staging].reverse());
    expect(drift(reordered).staging!.ok).toBe(false);
  });

  test("the checked-in lists boot production's newest roll in both environments", () => {
    for (const d of bootDrift(checkedIn)) expect({ env: d.env, image: d.image, ok: d.ok }).toEqual({ env: d.env, image: d.image, ok: true });
  });

  test("the CLI exits 1 on a stale list and 0 on the checked-in one", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "auto-roll-check-"));
    try {
      let text = wrangler;
      for (let run = 1; run <= 3; run++) text = approve(text, entry(String(950 + run))).text;
      const staging = locate(text, "staging").images;
      const file = path.join(dir, "wrangler.jsonc");
      writeFileSync(file, replaceList(text, "staging", staging.slice(0, -2)));
      const script = new URL("../../images/cmux-vm/auto-roll.ts", import.meta.url).pathname;
      const stale = await runChild("bun", [script, "check", "--wrangler", file]);
      expect(stale.status).toBe(1);
      expect(stale.stderr).toContain("staging boots");
      writeFileSync(file, text);
      const fresh = await runChild("bun", [script, "check", "--wrangler", file]);
      expect(fresh.status).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("auto-roll rollback", () => {
  test("takes the first auto-rolled image out of both lists, so the entry before it boots again", () => {
    const original = locate(wrangler, "production").images[0]!.id;
    const { text } = approve(wrangler, entry("200"));
    const result = rollback(text, entry("200").id);
    expect(result.rolledBack).toBe(true);
    expect(result.nowFirst).toBe(original);
    expect(locate(result.text, "production").images).toEqual(locate(wrangler, "production").images);
    expect(locate(result.text, "staging").images).toEqual(locate(wrangler, "staging").images);
  });

  test("removes a failed image a newer roll sits above, so that roll's own rollback cannot bring it back", () => {
    let text = approve(wrangler, entry("300")).text;
    text = approve(text, entry("301")).text;
    const result = rollback(text, entry("300").id);
    expect(result.rolledBack).toBe(true);
    expect(result.nowFirst).toBe(entry("301").id);
    const ids = (t: string) => [...locate(t, "production").images, ...locate(t, "staging").images].map((i) => i.id);
    expect(ids(result.text)).not.toContain(entry("300").id);
    // The newer roll fails too: its rollback leaves the hand-approved first entry, never the earlier failed image.
    const second = rollback(result.text, entry("301").id);
    expect(second.nowFirst).toBe(locate(wrangler, "production").images[0]!.id);
    expect(locate(second.text, "production").images).toEqual(locate(wrangler, "production").images);
    const gone = rollback(second.text, entry("300").id);
    expect(gone.rolledBack).toBe(false);
    expect(gone.reason).toMatch(/in neither list/);
  });

  test("rolls back an auto image only staging lists while production's list is empty, and production keeps its pin", () => {
    // An image staging lists (approve's staging entry, with staging's services) while production lists none.
    const both = approve(wrangler, entry("400")).text;
    const text = replaceList(both, "production", []);
    const result = rollback(text, entry("400").id);
    expect(result.rolledBack).toBe(true);
    expect(result.nowFirst).toBe("");
    expect(result.reason).toMatch(/boots its pin/);
    expect(locate(result.text, "staging").images.map((i) => i.id)).not.toContain(entry("400").id);
    expect(locate(result.text, "production").images).toEqual([]);
  });

  test("never rolls back a hand-approved image", () => {
    const first = locate(wrangler, "production").images[0]!.id;
    const result = rollback(wrangler, first);
    expect(result.rolledBack).toBe(false);
    expect(result.reason).toMatch(/not an auto-rolled image/);
  });
});

describe("auto-roll inputs", () => {
  test("the checked-in switch is a known mode", () => {
    expect(["off", "dry-run", "live"]).toContain(modeOf(readFileSync(new URL("../../images/cmux-vm/auto-roll.json", import.meta.url), "utf8")));
    expect(() => modeOf('{"mode":"on"}')).toThrow();
  });

  test("the entry carries the candidate's inputs_sha256 only when it is 64 lowercase hex", () => {
    expect(keyed("1").inputs_sha256).toBe(KEY);
    expect(entry("1")).not.toHaveProperty("inputs_sha256");
    for (const bad of ["", "f".repeat(63), "F".repeat(64), 42])
      expect(rolledImage({ ...candidate, inputs_sha256: bad as string }, "ci-1-1", tui, "1", "1")).not.toHaveProperty("inputs_sha256");
  });

  test("a candidate without a snapshot id or a cmux-tui commit makes no entry", () => {
    expect(() => rolledImage({ ...candidate, snapshot_id: "" }, "ci-1-1", tui, "1", "1")).toThrow();
    expect(() => rolledImage(candidate, "ci-1-1", "main", "1", "1")).toThrow();
    expect(() => rolledImage(candidate, "ci-1-1", tui, "1", "0")).toThrow(/attempt/);
  });
});

describe("auto-roll settle", () => {
  const image = entry("500").id;
  const previous = locate(wrangler, "production").images[0]!.id;
  const roll = (over: Partial<SettleInput>): SettleInput => ({
    kind: "roll", image, deploy: "success", product: "success", bootImage: image, deployedFirst: image, tipFirst: image, tipHas: true, deployedHas: true, deployedStagingHas: true, attempt: 1, ...over,
  });
  const back = (over: Partial<SettleInput>): SettleInput => ({
    kind: "rollback", image, deploy: "success", product: "success", bootImage: previous, deployedFirst: previous, tipFirst: previous, tipHas: false, deployedHas: false, deployedStagingHas: false, attempt: 1, ...over,
  });

  test("a roll whose deploy and product create booted the image is green", () => {
    expect(settle(roll({})).outcome).toBe("green");
  });

  test("a cancelled, timed out or failed deploy rolls back while the image is still first at the tip", () => {
    for (const deploy of ["cancelled", "failure", "skipped", ""]) expect(settle(roll({ deploy, product: "" })).outcome).toBe("rollback");
    expect(settle(roll({ product: "failure" })).outcome).toBe("rollback");
    // A green create that booted some other image proves nothing about this one.
    expect(settle(roll({ bootImage: previous })).outcome).toBe("rollback");
  });

  test("a failed roll a newer roll sits above still rolls back; only an image gone from both lists is superseded", () => {
    const newer = entry("501").id;
    expect(settle(roll({ deploy: "cancelled", product: "", tipFirst: newer })).outcome).toBe("rollback");
    expect(settle(roll({ deploy: "failure", product: "", tipFirst: newer, tipHas: true })).outcome).toBe("rollback");
    expect(settle(roll({ deploy: "failure", product: "", tipFirst: previous, tipHas: false })).outcome).toBe("superseded");
  });

  test("a rollback is verified only when the create booted the deployed first entry, not the rolled-back image", () => {
    expect(settle(back({})).outcome).toBe("verified");
    expect(settle(back({ bootImage: image })).outcome).not.toBe("verified");
    expect(settle(back({ deployedFirst: image, bootImage: image, deployedHas: true })).outcome).not.toBe("verified");
    // Still in the deployed list below another first entry: not taken out yet.
    expect(settle(back({ deployedHas: true })).outcome).not.toBe("verified");
    expect(settle(back({ bootImage: "" })).outcome).not.toBe("verified");
  });

  test("an unverified rollback retries its deploy, at most ROLLBACK_DEPLOYS deploys, then is rollback_failed", () => {
    expect(ROLLBACK_DEPLOYS).toBe(3);
    for (let attempt = 1; attempt < ROLLBACK_DEPLOYS; attempt++) {
      expect(settle(back({ deploy: "failure", product: "", attempt }))).toMatchObject({ outcome: "retry", nextAttempt: attempt + 1 });
    }
    expect(settle(back({ deploy: "cancelled", product: "", attempt: ROLLBACK_DEPLOYS })).outcome).toBe("rollback_failed");
  });

  test("a staging-only rollback with no production image is verified by the deployed lists, not a production boot", () => {
    // Production lists nothing (it boots its pin), so no create boots a "first entry".
    const none = { deployedFirst: "", tipFirst: "", bootImage: "", product: "" };
    expect(settle(back(none)).outcome).toBe("verified");
    expect(settle(back(none)).reason).toMatch(/boots its pin/);
    // Still in staging in the deployed commit, or a deploy that did not succeed: not verified.
    expect(settle(back({ ...none, deployedStagingHas: true })).outcome).toBe("retry");
    expect(settle(back({ ...none, deploy: "failure" })).outcome).toBe("retry");
  });

  test("a rollback's settle never asks for another rollback commit", () => {
    for (const deploy of ["success", "failure", "cancelled"])
      for (const attempt of [1, 2, 3, 4]) expect(settle(back({ deploy, product: "failure", attempt })).outcome).not.toBe("rollback");
  });

  test("the CLI reads the deployed and tip first entries from wrangler.jsonc files", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "auto-roll-settle-"));
    try {
      const rolled = approve(wrangler, entry("500")).text;
      writeFileSync(path.join(dir, "deployed.jsonc"), rolled);
      writeFileSync(path.join(dir, "tip.jsonc"), rolled);
      const script = new URL("../../images/cmux-vm/auto-roll.ts", import.meta.url).pathname;
      const run = async (deploy: string) => {
        const r = await runChild("bun", [script, "settle", "--kind", "roll", "--image", image, "--deploy", deploy, "--product", "", "--boot-image", "",
          "--deployed-wrangler", path.join(dir, "deployed.jsonc"), "--wrangler", path.join(dir, "tip.jsonc")]);
        expect(r.status).toBe(0);
        return JSON.parse(r.stdout) as { outcome: string; tipFirst: string; deployedFirst: string };
      };
      expect(await run("cancelled")).toMatchObject({ outcome: "rollback", tipFirst: image, deployedFirst: image });
      writeFileSync(path.join(dir, "tip.jsonc"), rollback(rolled, image).text);
      expect(await run("cancelled")).toMatchObject({ outcome: "superseded", tipFirst: previous });
      // A newer roll on top of this failed one: the image is still listed, so it rolls back.
      writeFileSync(path.join(dir, "tip.jsonc"), approve(rolled, entry("502")).text);
      expect(await run("cancelled")).toMatchObject({ outcome: "rollback", tipFirst: entry("502").id });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

// The workflows that run the decisions above: they read settle's outcome and never decide on their own.
describe("auto-roll workflows", () => {
  const { YAML } = (globalThis as unknown as { Bun: { YAML: { parse(text: string): unknown } } }).Bun;
  type Step = { name?: string; id?: string; if?: string; run?: string; env?: Record<string, string>; uses?: string; with?: Record<string, unknown> };
  type Job = { if?: string; permissions?: Record<string, string>; steps: Step[] };
  const load = (name: string) =>
    YAML.parse(readFileSync(new URL(`../../.github/workflows/${name}`, import.meta.url), "utf8")) as {
      on: { workflow_dispatch: { inputs: Record<string, unknown> } };
      jobs: Record<string, Job>;
    };
  const vm = load("cmux-vm.yml");
  const settleJob = vm.jobs["image-roll-settle"]!;
  const stepOf = (job: Job, id: string) => job.steps.find((s) => s.id === id)!;

  test("settle runs after a roll commit, a rollback commit and a rollback's retried deploy", () => {
    expect(settleJob.if).toContain("startsWith(github.event.head_commit.message, 'cmux-vm: image roll')");
    expect(settleJob.if).toContain("inputs.action == 'deploy-production' && inputs.image_rollback != ''");
    for (const input of ["image_rollback", "image_roll_run", "image_rollback_attempt"]) expect(vm.on.workflow_dispatch.inputs).toHaveProperty(input);
  });

  test("settle takes its outcome from auto-roll.ts settle, with no cancelled shortcut", () => {
    expect(stepOf(settleJob, "deploy-mode").run).toContain("cmux-platform owns deploy and settle");
    expect(stepOf(settleJob, "roll").if).toBe("steps.deploy-mode.outputs.enabled == 'true'");
    const read = stepOf(settleJob, "roll").run!;
    expect(read).toContain("auto-roll.ts settle");
    expect(read).not.toMatch(/cancelled/);
    expect(stepOf(settleJob, "rollback").if).toBe("steps.deploy-mode.outputs.enabled == 'true' && steps.roll.outputs.outcome == 'rollback'");
    expect(stepOf(settleJob, "push-token").if).toBe("steps.deploy-mode.outputs.enabled == 'true' && steps.roll.outputs.outcome == 'rollback'");
    const retry = stepOf(settleJob, "retry");
    expect(retry.if).toBe("steps.deploy-mode.outputs.enabled == 'true' && steps.roll.outputs.outcome == 'retry'");
    expect(retry.run).toContain("-f action=deploy-production");
    expect(retry.run).toContain('-f image_rollback_attempt="$NEXT"');
    expect(settleJob.permissions).toMatchObject({ actions: "write" });
  });

  test("the product smoke boots the first image on a roll, a rollback and a retried rollback deploy, and says which", () => {
    const smoke = vm.jobs["smoke-production"]!;
    const product = stepOf(smoke, "product");
    expect(product.env!["CMUX_VM_SMOKE_IMAGE"]).toContain("!startsWith(github.event.head_commit.message, 'cmux-vm: image roll') && inputs.image_rollback == ''");
    expect((smoke as unknown as { outputs: Record<string, string> }).outputs["boot_image"]).toBe("${{ steps.product.outputs.boot_image }}");
  });

  test("the roll bakes the plain image and hands back its channel-dev.json record", () => {
    const roll = load("cloud-vm-image-roll.yml") as unknown as { jobs: { bake: { with: Record<string, unknown> } } };
    expect(roll.jobs.bake.with).toMatchObject({ mode: "bake", keep_snapshot: true, agent_tools: true, roll: true });
    expect(roll.jobs.bake.with).not.toHaveProperty("native_receiver");
    const bake = load("cloud-vm-image-bake.yml");
    expect(stepOf(bake.jobs["bake"]!, "roll_candidate").run).toContain('"$OUT_DIR/channel-dev.json"');
  });

  // A large snapshot nothing can publish is a wasted bake and an orphan at the provider. The publish step can write
  // it only when the switch is on, the tip's Worker reads `large` (the plan asks it) and this repository deploys
  // the Worker itself: in platform mode the lists are cmux-platform's, written from a checkout with no Worker source.
  test("the roll asks the bake for the large image only when the publish step could write it", () => {
    type RollJob = Job & { needs?: string | string[]; outputs?: Record<string, string>; with?: Record<string, unknown>; environment?: string; "runs-on"?: string };
    const roll = load("cloud-vm-image-roll.yml") as unknown as { jobs: Record<string, RollJob> };
    expect(roll.jobs["plan"]!.outputs!["large"]).toBe("${{ steps.plan.outputs.large }}");
    const planRun = stepOf(roll.jobs["plan"]!, "plan").run!;
    expect(planRun).toContain('echo "large=$(jq -r .large "$RUNNER_TEMP/plan.json")"');
    // The plan job holds no secret and no environment, and installs the Worker's dependencies with no package scripts.
    expect(roll.jobs["plan"]).not.toHaveProperty("environment");
    expect(planRun).toContain("bun install --frozen-lockfile --ignore-scripts");
    // Which repository deploys is a variable of the production environment, so its own job reads it, and only when
    // the plan already wants a large image: with the switch off no roll runs it.
    const mode = roll.jobs["publish-mode"]!;
    expect(mode.needs).toBe("plan");
    expect(mode.if).toBe("needs.plan.outputs.roll == 'true' && needs.plan.outputs.large == 'true'");
    expect(mode.environment).toBe("cmux-vm-production");
    expect(mode.outputs!["direct"]).toBe("${{ steps.mode.outputs.direct }}");
    expect(stepOf(mode, "mode").env).toEqual({ ENABLED: "${{ vars.CMUX_VM_DEPLOY_ENABLED }}" });
    expect(mode["runs-on"]).toMatch(/\|\| fromJSON\(vars\.RUNNER_POOLS\)\.linux_4 }}$/);
    const bake = roll.jobs["bake"]!;
    expect(bake.with!["large_image"]).toBe("${{ needs.plan.outputs.large == 'true' && needs.publish-mode.outputs.direct == 'true' }}");
    // A skipped publish-mode (every roll with the switch off) must not skip the bake or the promotion after it.
    expect(bake.needs).toEqual(["plan", "publish-mode"]);
    expect(bake.if).toBe("${{ !cancelled() && needs.plan.result == 'success' && needs.plan.outputs.roll == 'true' }}");
    expect(roll.jobs["promote"]!.if).toBe("${{ !cancelled() && needs.plan.outputs.roll == 'true' && needs.bake.result == 'success' && needs.bake.outputs.candidate != '' }}");
  });

  test("the mode step says direct only for the deploy variable's exact value", async () => {
    const roll = load("cloud-vm-image-roll.yml");
    const step = stepOf(roll.jobs["publish-mode"]!, "mode");
    const dir = mkdtempSync(path.join(tmpdir(), "auto-roll-mode-"));
    try {
      const run = async (enabled: string) => {
        const output = path.join(dir, `output-${enabled || "unset"}`);
        const summary = path.join(dir, `summary-${enabled || "unset"}`);
        const r = await runChild("bash", ["-c", step.run!], { env: { PATH: process.env["PATH"], ENABLED: enabled, GITHUB_OUTPUT: output, GITHUB_STEP_SUMMARY: summary } });
        expect(r.status).toBe(0);
        return { output: readFileSync(output, "utf8").trim(), summary: readFileSync(summary, "utf8") };
      };
      expect((await run("1")).output).toBe("direct=true");
      for (const other of ["", "0", "true"]) {
        const platform = await run(other);
        expect(platform.output).toBe("direct=false");
        expect(platform.summary).toMatch(/large image is not baked/);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("the promote job says what the roll dropped or left unpublished, whatever the push step did", () => {
    const promote = load("cloud-vm-image-roll.yml").jobs["promote"]!;
    const notes = stepOf(promote, "notes");
    expect(notes.if).toBe("${{ !cancelled() }}");
    expect(notes.env).toEqual({ RESULT: "${{ steps.push.outputs.result }}" });
    expect(notes.run).toContain("auto-roll.ts notes");
    expect(notes.run).toContain('>> "$GITHUB_STEP_SUMMARY"');
    expect(promote.steps.findIndex((s) => s.id === "notes")).toBeGreaterThan(promote.steps.findIndex((s) => s.id === "push"));
  });

  // A revert of the Worker's parser beside a list that already carries `large` is not a roll commit, so it takes the
  // full check: the lists check has to run there too, before staging and production deploy that commit.
  test("every cmux-vm check runs the lists check, which knows what this commit's Worker reads", () => {
    const check = vm.jobs["check"]!.steps.find((s) => s.name?.startsWith("Boot image lists and the image lock parse"))!;
    expect(check.run).toContain("bun images/cmux-vm/auto-roll.ts lists");
    expect(check.if).toBe("${{ !cancelled() && steps.install.outcome == 'success' }}");
  });

  test("a roll's image id carries the run attempt", () => {
    const roll = load("cloud-vm-image-roll.yml");
    const promote = roll.jobs["promote"]!;
    expect(stepOf(promote, "message").run).toContain('image="cloud-native-auto-${tui:0:8}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"');
    expect(stepOf(promote, "push").run).toContain('--attempt "$GITHUB_RUN_ATTEMPT"');
  });

  // Roll 44282278310 (2026-11-18): with vars.LINUX_RUNNER on a 16-vCPU Blacksmith size, plan queued 41 min and
  // promote 20+ min for that size, each a minute of work. Only the bake needs the big runner.
  test("the roll's control jobs take the 4-vCPU pool, never LINUX_RUNNER; the bake keeps it", () => {
    const roll = load("cloud-vm-image-roll.yml") as unknown as { jobs: Record<string, { "runs-on"?: string }> };
    for (const job of ["platform-readiness", "plan", "promote", "report"]) {
      const runsOn = roll.jobs[job]!["runs-on"]!;
      expect(runsOn).not.toContain("vars.LINUX_RUNNER");
      expect(runsOn).toMatch(/\|\| fromJSON\(vars\.RUNNER_POOLS\)\.linux_4 }}$/);
      expect(runsOn).toContain("vars.CI_CLOUD_OVERFLOW_SAVED && fromJSON(vars.RUNNER_POOLS).linux_8 ||");
    }
    const bake = load("cloud-vm-image-bake.yml") as unknown as { jobs: Record<string, { "runs-on"?: string }> };
    // The bake takes the one Linux label (scripts/ci/one_linux_label.py), never a size.
    expect(bake.jobs["bake"]!["runs-on"]).toMatch(/\|\| 'cmux-linux' }}$/);
  });

  test("platform mode mints its scoped token, checks out main and passes the split checkout", () => {
    const roll = load("cloud-vm-image-roll.yml");
    const promote = roll.jobs["promote"]!;
    const token = stepOf(promote, "platform-token");
    expect(token.if).toContain("CMUX_VM_DEPLOY_ENABLED != '1'");
    expect(token.with).toMatchObject({ owner: "manaflow-ai", repositories: "cmux-platform", "permission-contents": "write" });
    const checkout = promote.steps.find((step) => step.with?.path === "cmux-platform");
    expect(checkout?.with).toMatchObject({ repository: "manaflow-ai/cmux-platform", ref: "main" });
    expect(stepOf(promote, "push").env).toMatchObject({ PLATFORM_CHECKOUT: expect.stringContaining("cmux-platform") });
    expect(stepOf(promote, "push").run).toContain("--platform-checkout");
  });

  test("readiness dispatch mints the platform grant and reads main without a push", () => {
    const roll = load("cloud-vm-image-roll.yml");
    expect(roll.on.workflow_dispatch.inputs.platform_readiness).toMatchObject({ default: false, type: "boolean" });
    const readiness = roll.jobs["platform-readiness"]!;
    const token = stepOf(readiness, "platform-token");
    expect(token.with).toMatchObject({ owner: "manaflow-ai", repositories: "cmux-platform", "permission-contents": "write" });
    expect(readiness.steps.find((step) => step.name === "Read cmux-platform main's Wrangler config")?.run).toContain("test -s");
  });
});

// The shell steps around the decisions, run for real against local git remotes (file://).
describe("auto-roll scripts", () => {
  const repoRoot = new URL("../../", import.meta.url).pathname;
  const gitEnv = { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@example.com", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@example.com" };
  const git = (cwd: string, ...args: string[]) => runChildOk("git", args, { cwd, env: gitEnv });
  const withDir = async (body: (dir: string) => Promise<void>) => {
    const dir = mkdtempSync(path.join(tmpdir(), "auto-roll-script-"));
    try {
      await body(dir);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  };

  test("the record script writes the first record, deep-merges rollback deploys and never lets a null erase one", () =>
    withDir(async (dir) => {
      await git(dir, "init", "-q", "--bare", "remote.git");
      const record = async (patch: object) =>
        runChildOk("bash", [path.join(repoRoot, "images/cmux-vm/image-roll-record.sh"), "77"], {
          cwd: dir,
          input: JSON.stringify(patch),
          env: { ...gitEnv, TOKEN: "unused", GITHUB_REPOSITORY: "remote", GITHUB_SERVER_URL: `file://${dir}`, CMUX_IMAGE_ROLL_BRANCH: "cloud-image-rolls" },
        });
      const read = async () => JSON.parse((await git(path.join(dir, "remote.git"), "show", "cloud-image-rolls:rolls/77.json")).stdout) as Record<string, unknown>;
      // No record yet: the patch is the record.
      await record({ schema: 1, gate: { result: "passed" } });
      expect(await read()).toEqual({ schema: 1, gate: { result: "passed" } });
      await record({ rollback: { result: "pushed", commit: "abc" } });
      await record({ rollback: { result: "retrying", deploys: { "1": { deploy: "failure" } } } });
      await record({ rollback: { result: "verified", deploys: { "2": { deploy: "success" } } } });
      // A re-run of the roll's settle (now superseded) patches rollback: null.
      await record({ production: { superseded: true }, rollback: null });
      expect(await read()).toEqual({
        schema: 1,
        gate: { result: "passed" },
        production: { superseded: true },
        rollback: { result: "verified", commit: "abc", deploys: { "1": { deploy: "failure" }, "2": { deploy: "success" } } },
      });
    }), 60_000);

  test("the push script names the image with the workflow run attempt, not its own push retry counter", () =>
    withDir(async (dir) => {
      const src = path.join(dir, "src");
      for (const file of ["images/cmux-vm/auto-roll.ts", "images/cmux-vm/auto-roll.json", "images/cmux-vm/fallback-image.json", "images/cmux-vm/inputs.lock.json", "images/cmux-vm/image-roll-push.sh", "workers/cmux-vm/wrangler.jsonc"]) {
        mkdirSync(path.dirname(path.join(src, file)), { recursive: true });
        copyFileSync(path.join(repoRoot, file), path.join(src, file));
      }
      await git(dir, "init", "-q", "--bare", "remote.git");
      await git(dir, "init", "-q", "-b", "feat-cmux-next", src);
      await git(src, "add", ".");
      await git(src, "commit", "-q", "-m", "base");
      await git(src, "remote", "add", "origin", path.join(dir, "remote.git"));
      await git(src, "push", "-q", "origin", "feat-cmux-next");
      const lock = readFileSync(path.join(src, "images/cmux-vm/inputs.lock.json"));
      const temp = path.join(dir, "runner-temp");
      mkdirSync(temp);
      writeFileSync(path.join(temp, "candidate.json"), JSON.stringify({ ...candidate, lock_sha256: createHash("sha256").update(lock).digest("hex") }));
      writeFileSync(path.join(temp, "message.txt"), "cmux-vm: image roll test\n");
      const out = await runChildOk(
        "bash",
        ["images/cmux-vm/image-roll-push.sh", "roll", "--candidate", path.join(temp, "candidate.json"), "--revision", "ci-4242-2", "--run", "4242",
          "--attempt", "2", "--message-file", path.join(temp, "message.txt"), "--dry-run"],
        { cwd: src, env: { ...gitEnv, RUNNER_TEMP: temp, GITHUB_OUTPUT: path.join(temp, "output") } },
      );
      expect(out.stdout.trim().split("\n").at(-1)).toMatch(/^dry-run [0-9a-f]{40}/);
      const approved = JSON.parse(readFileSync(path.join(temp, "approve.json"), "utf8")) as { image: { id: string } };
      expect(approved.image.id).toMatch(/^cloud-native-auto-[0-9a-f]{8}-4242-2$/);
    }), 60_000);

  test("the push script's roll commit carries the candidate's large image only when the tip's switch is on and its Worker reads it", () =>
    withDir(async (dir) => {
      const src = path.join(dir, "src");
      for (const file of ["images/cmux-vm/auto-roll.ts", "images/cmux-vm/auto-roll.json", "images/cmux-vm/fallback-image.json", "images/cmux-vm/inputs.lock.json", "images/cmux-vm/image-roll-push.sh", "workers/cmux-vm/wrangler.jsonc"]) {
        mkdirSync(path.dirname(path.join(src, file)), { recursive: true });
        copyFileSync(path.join(repoRoot, file), path.join(src, file));
      }
      const switchFile = path.join(src, "images/cmux-vm/auto-roll.json");
      const parser = path.join(src, "workers/cmux-vm/src/upstream/live-images.ts");
      mkdirSync(path.dirname(parser), { recursive: true });
      // The tip's state: the roll's switch, and whether the Worker deployed from that commit reads `large`
      // (today's refuses the whole list for the unknown field).
      const tip = (on: boolean, reads: boolean) => {
        writeFileSync(switchFile, `${JSON.stringify({ mode: "live", large_image: on }, null, 2)}\n`);
        writeFileSync(parser, reads
          ? `export const parseVmImages = (raw: string) => ({ ok: true, images: JSON.parse(raw) });\n`
          : `export const parseVmImages = (raw: string) => (raw.includes('"large"') ? { ok: false, images: [] } : { ok: true, images: JSON.parse(raw) });\n`);
      };
      // The push script starts every attempt from the fetched tip, so a new state has to land there.
      const land = async (on: boolean, reads: boolean, message: string) => {
        await git(src, "checkout", "-q", "-B", "feat-cmux-next", "origin/feat-cmux-next");
        tip(on, reads);
        await git(src, "add", ".");
        await git(src, "commit", "-q", "-m", message);
        await git(src, "push", "-q", "origin", "feat-cmux-next");
      };
      tip(false, true);
      await git(dir, "init", "-q", "--bare", "remote.git");
      await git(dir, "init", "-q", "-b", "feat-cmux-next", src);
      await git(src, "add", ".");
      await git(src, "commit", "-q", "-m", "base");
      await git(src, "remote", "add", "origin", path.join(dir, "remote.git"));
      await git(src, "push", "-q", "origin", "feat-cmux-next");
      const lock = readFileSync(path.join(src, "images/cmux-vm/inputs.lock.json"));
      const temp = path.join(dir, "runner-temp");
      mkdirSync(temp);
      writeFileSync(path.join(temp, "candidate.json"), JSON.stringify({ ...candidate, lock_sha256: createHash("sha256").update(lock).digest("hex"), large: LARGE_CANDIDATE }));
      writeFileSync(path.join(temp, "message.txt"), "cmux-vm: image roll test\n");
      const roll = async (run: string) => {
        await runChildOk(
          "bash",
          ["images/cmux-vm/image-roll-push.sh", "roll", "--candidate", path.join(temp, "candidate.json"), "--revision", `ci-${run}-1`, "--run", run,
            "--attempt", "1", "--message-file", path.join(temp, "message.txt"), "--dry-run"],
          { cwd: src, env: { ...gitEnv, RUNNER_TEMP: temp, GITHUB_OUTPUT: path.join(temp, "output") } },
        );
        const text = (await git(src, "show", "HEAD:workers/cmux-vm/wrangler.jsonc")).stdout;
        return {
          approved: JSON.parse(readFileSync(path.join(temp, "approve.json"), "utf8")) as { image: { id: string; large?: unknown } },
          prod: locate(text, "production").images[0]!,
          staging: locate(text, "staging").images.at(-1)!,
        };
      };
      // The switch is off at the tip, or it is on beside a Worker that would refuse the list: the same candidate
      // rolls as it does today, in both lists.
      const off = await roll("4301");
      await land(true, false, "large on, a Worker that does not read it");
      const unread = await roll("4302");
      for (const [rolled, run] of [[off, "4301"], [unread, "4302"]] as const) {
        expect(rolled.prod.id).toMatch(new RegExp(`-${run}-1$`));
        expect(rolled.prod).not.toHaveProperty("large");
        expect(rolled.staging).not.toHaveProperty("large");
        expect(rolled.approved.image.large ?? null).toBeNull();
      }
      await land(true, true, "the Worker reads large");
      const on = await roll("4303");
      expect(on.prod.id).toMatch(/-4303-1$/);
      expect(on.prod.large).toEqual(LARGE_ENTRY);
      expect(on.staging.large).toEqual(LARGE_ENTRY);
      expect(on.approved.image.large).toEqual(LARGE_ENTRY);
    }), 60_000);

  test("platform mode pushes Wrangler first and leaves cmux with a lock-only commit", () =>
    withDir(async (dir) => {
      const src = path.join(dir, "src");
      const platform = path.join(dir, "platform");
      for (const file of ["images/cmux-vm/auto-roll.ts", "images/cmux-vm/auto-roll.json", "images/cmux-vm/fallback-image.json", "images/cmux-vm/inputs.lock.json", "images/cmux-vm/image-roll-push.sh", "workers/cmux-vm/wrangler.jsonc"]) {
        mkdirSync(path.dirname(path.join(src, file)), { recursive: true });
        copyFileSync(path.join(repoRoot, file), path.join(src, file));
      }
      // The switch is on, and cmux's own Worker reads `large`: neither is the Worker that serves cmux-platform's list.
      writeFileSync(path.join(src, "images/cmux-vm/auto-roll.json"), `${JSON.stringify({ mode: "live", large_image: true }, null, 2)}\n`);
      mkdirSync(path.join(src, "workers/cmux-vm/src/upstream"), { recursive: true });
      writeFileSync(path.join(src, "workers/cmux-vm/src/upstream/live-images.ts"), `export const parseVmImages = (raw: string) => ({ ok: true, images: JSON.parse(raw) });\n`);
      mkdirSync(path.join(platform, "workers/cmux-vm"), { recursive: true });
      copyFileSync(path.join(repoRoot, "workers/cmux-vm/wrangler.jsonc"), path.join(platform, "workers/cmux-vm/wrangler.jsonc"));
      await git(dir, "init", "-q", "--bare", "cmux.git");
      await git(dir, "init", "-q", "--bare", "platform.git");
      await git(dir, "init", "-q", "-b", "feat-cmux-next", src);
      await git(src, "add", ".");
      await git(src, "commit", "-q", "-m", "base");
      await git(src, "remote", "add", "origin", path.join(dir, "cmux.git"));
      await git(src, "push", "-q", "origin", "feat-cmux-next");
      await git(dir, "init", "-q", "-b", "main", platform);
      await git(platform, "add", ".");
      await git(platform, "commit", "-q", "-m", "base");
      await git(platform, "remote", "add", "origin", path.join(dir, "platform.git"));
      await git(platform, "push", "-q", "origin", "main");
      const lock = readFileSync(path.join(src, "images/cmux-vm/inputs.lock.json"), "utf8");
      // The same cmux-tui as the lock: the never-older check (auto-roll.ts behind) passes without that commit's history.
      const pinned = (JSON.parse(lock) as { programs: { name: string; version: string }[] }).programs.find((program) => program.name === "cmux-tui")?.version ?? "";
      const temp = path.join(dir, "runner-temp");
      const fakeBin = path.join(dir, "bin");
      mkdirSync(temp);
      mkdirSync(fakeBin);
      // A candidate that records a large image (a bake from before the plan knew the mode, or a hand dispatch).
      writeFileSync(path.join(temp, "candidate.json"), JSON.stringify({ ...candidate, lock_sha256: createHash("sha256").update(`${lock}\n`).digest("hex"), large: LARGE_CANDIDATE }));
      writeFileSync(path.join(temp, "message.txt"), "cmux-vm: image roll platform test\n\nImage-Roll-Run: 4242\nImage-Roll-Image: cloud-native-auto-12345678-4242-2\n");
      const realBun = (await runChildOk("bash", ["-c", "command -v bun"], { env: process.env })).stdout.trim();
      writeFileSync(path.join(fakeBin, "bun"), `#!/usr/bin/env bash\nif [ "\${1:-}" = "images/cmux-vm/pin-cmux-tui.ts" ]; then printf '\\n' >> "$(pwd)/images/cmux-vm/inputs.lock.json"; exit 0; fi\nexec ${realBun} "$@"\n`);
      await runChildOk("chmod", ["+x", path.join(fakeBin, "bun")]);
      const out = await runChildOk(
        "bash",
        ["images/cmux-vm/image-roll-push.sh", "roll", "--candidate", path.join(temp, "candidate.json"), "--revision", "ci-4242-2", "--run", "4242", "--attempt", "2", "--pin", pinned, "--message-file", path.join(temp, "message.txt"), "--platform-checkout", platform, "--dry-run"],
        { cwd: src, env: { ...gitEnv, PATH: `${fakeBin}:${process.env.PATH}`, PLATFORM_TOKEN: "unused", RUNNER_TEMP: temp, GITHUB_OUTPUT: path.join(temp, "output") } },
      );
      expect(out.stdout.trim().split("\n").at(-1)).toMatch(/^dry-run [0-9a-f]{40}/);
      expect((await git(platform, "show", "--format=", "--name-only", "HEAD")).stdout.trim()).toBe("workers/cmux-vm/wrangler.jsonc");
      expect((await git(src, "show", "--format=", "--name-only", "HEAD")).stdout.trim()).toBe("images/cmux-vm/inputs.lock.json");
      expect((await git(platform, "log", "-1", "--format=%s")).stdout.trim()).toBe("cmux-vm: image roll platform test");
      expect((await git(src, "log", "-1", "--format=%s")).stdout.trim()).toBe("cmux-vm: image roll platform test");
      // The platform checkout has no Worker source to ask, so its lists get the image without `large`, and the
      // notes name the large snapshot that was baked for nothing.
      const platformText = (await git(platform, "show", "HEAD:workers/cmux-vm/wrangler.jsonc")).stdout;
      expect(locate(platformText, "production").images[0]!.id).toMatch(/^cloud-native-auto-[0-9a-f]{8}-4242-2$/);
      expect(locate(platformText, "production").images[0]).not.toHaveProperty("large");
      expect(locate(platformText, "staging").images.at(-1)).not.toHaveProperty("large");
      const notes = await runChildOk("bun", [path.join(src, "images/cmux-vm/auto-roll.ts"), "notes", "--candidate", path.join(temp, "candidate.json"), "--approve", path.join(temp, "approve.json"), "--result", "pushed"]);
      expect(notes.stdout).toContain(LARGE_CANDIDATE.snapshot);
      expect(notes.stdout).toMatch(/not published/);
    }), 60_000);

  test("the plan asks for a large image only with the switch on beside a Worker that reads it", () =>
    withDir(async (dir) => {
      const script = path.join(repoRoot, "images/cmux-vm/auto-roll.ts");
      const lock = path.join(dir, "lock.json");
      writeFileSync(lock, JSON.stringify({ programs: [{ name: "cmux-tui", version: "a".repeat(40) }] }));
      const worker = (name: string, source: string) => {
        const root = path.join(dir, name);
        mkdirSync(path.join(root, "src/upstream"), { recursive: true });
        writeFileSync(path.join(root, "src/upstream/live-images.ts"), source);
        return root;
      };
      const reads = worker("reads", `export const parseVmImages = (raw: string) => ({ ok: true, images: JSON.parse(raw) });`);
      const strict = worker("strict", `export const parseVmImages = (raw: string) => (raw.includes('"large"') ? { ok: false, images: [] } : { ok: true, images: JSON.parse(raw) });`);
      const plan = async (on: boolean | undefined, workerDir: string) => {
        const modeFile = path.join(dir, "auto-roll.json");
        writeFileSync(modeFile, JSON.stringify(on === undefined ? { mode: "live" } : { mode: "live", large_image: on }));
        const r = await runChildOk("bun", [script, "plan", "--event", "dispatch", "--lock", lock, "--mode-file", modeFile, "--worker", workerDir]);
        return JSON.parse(r.stdout) as { roll: boolean; large: boolean; largeReason: string };
      };
      expect(await plan(true, reads)).toMatchObject({ roll: true, large: true });
      expect(await plan(false, reads)).toMatchObject({ roll: true, large: false, largeReason: expect.stringContaining("large_image") });
      expect(await plan(undefined, reads)).toMatchObject({ roll: true, large: false });
      expect(await plan(true, strict)).toMatchObject({ roll: true, large: false, largeReason: expect.stringContaining("does not read `large`") });
      expect(await plan(true, path.join(dir, "no-worker"))).toMatchObject({ roll: true, large: false, largeReason: expect.stringContaining("does not read `large`") });
    }), 60_000);

  test("plan fails closed on a shallow checkout or a pin it lacks, and still refuses a build older than the pin", () =>
    withDir(async (dir) => {
      const full = path.join(dir, "full");
      await git(dir, "init", "-q", "-b", "feat-cmux-next", full);
      const commitOf = async (msg: string) => {
        await git(full, "commit", "-q", "--allow-empty", "-m", msg);
        return (await git(full, "rev-parse", "HEAD")).stdout.trim();
      };
      const older = await commitOf("older");
      const pinned = await commitOf("pinned");
      const tip = await commitOf("tip");
      const lock = path.join(dir, "lock.json");
      writeFileSync(lock, JSON.stringify({ programs: [{ name: "cmux-tui", version: pinned }] }));
      const script = path.join(repoRoot, "images/cmux-vm/auto-roll.ts");
      const plan = (repo: string, commit: string) => runChild("bun", [script, "plan", "--event", "build", "--commit", commit, "--tip", "HEAD", "--lock", lock, "--repo", repo]);

      const ok = await plan(full, older);
      expect(ok.status).toBe(0);
      const decided = JSON.parse(ok.stdout) as { roll: boolean; reason: string; large: unknown };
      // The plan says whether the bake makes the large image (auto-roll.json large_image).
      expect(typeof decided.large).toBe("boolean");
      expect(decided.roll).toBe(false);
      expect(decided.reason).toMatch(/older than the pinned/);

      // A depth-1 clone of the tip: the old build is unreachable, the guard cannot decide, the plan errors.
      const shallow = path.join(dir, "shallow");
      await git(dir, "clone", "-q", "--depth", "1", "--branch", "feat-cmux-next", `file://${full}`, shallow);
      const cut = await plan(shallow, tip);
      expect(cut.status).not.toBe(0);
      expect(cut.stderr).toMatch(/shallow/);
      // A build outside the shallow history: the branch check would answer "not on the branch" (roll: false) from
      // the cut alone, so the shallow refusal has to come first (review of #37409, F1).
      const beyond = await plan(shallow, older);
      expect(beyond.status).not.toBe(0);
      expect(beyond.stderr).toMatch(/shallow/);

      // Full history without the pinned commit (a pin off the branch that was never fetched).
      writeFileSync(lock, JSON.stringify({ programs: [{ name: "cmux-tui", version: "f".repeat(40) }] }));
      const missing = await plan(full, tip);
      expect(missing.status).not.toBe(0);
      expect(missing.stderr).toMatch(/not in this checkout/);
    }), 60_000);

  // Roll 44191283358's re-run (attempt 2) promoted cmux-tui 6c776483 at 2026-11-18 04:53Z over roll 44224051230's
  // newer ecd5f536 (04:30Z): plan() refused an older build only against the pin at plan time.
  test("behind refuses a pin older than the tip's, allows the same or a newer one, and fails closed when shallow", () =>
    withDir(async (dir) => {
      const full = path.join(dir, "full");
      await git(dir, "init", "-q", "-b", "feat-cmux-next", full);
      const commitOf = async (msg: string) => {
        await git(full, "commit", "-q", "--allow-empty", "-m", msg);
        return (await git(full, "rev-parse", "HEAD")).stdout.trim();
      };
      const older = await commitOf("older");
      const pinned = await commitOf("pinned");
      const newer = await commitOf("newer");
      const lock = path.join(dir, "lock.json");
      writeFileSync(lock, JSON.stringify({ programs: [{ name: "cmux-tui", version: pinned }] }));
      const script = path.join(repoRoot, "images/cmux-vm/auto-roll.ts");
      const behind = (repo: string, pin: string) => runChild("bun", [script, "behind", "--pin", pin, "--lock", lock, "--repo", repo]);

      const back = await behind(full, older);
      expect(back.status).toBe(3);
      expect((JSON.parse(back.stdout) as { reason: string }).reason).toMatch(/older than the tip's pinned/);
      expect((await behind(full, pinned)).status).toBe(0);
      expect((await behind(full, newer)).status).toBe(0);

      const shallow = path.join(dir, "shallow");
      await git(dir, "clone", "-q", "--depth", "1", "--branch", "feat-cmux-next", `file://${full}`, shallow);
      const cut = await behind(shallow, older);
      expect(cut.status).not.toBe(0);
      expect(cut.status).not.toBe(3);
      expect(cut.stderr).toMatch(/shallow/);
    }), 60_000);

  test("the push script lands nothing when a newer roll pinned a newer cmux-tui while this one baked", () =>
    withDir(async (dir) => {
      const src = path.join(dir, "src");
      for (const file of ["images/cmux-vm/auto-roll.ts", "images/cmux-vm/auto-roll.json", "images/cmux-vm/fallback-image.json", "images/cmux-vm/inputs.lock.json", "images/cmux-vm/image-roll-push.sh", "workers/cmux-vm/wrangler.jsonc"]) {
        mkdirSync(path.dirname(path.join(src, file)), { recursive: true });
        copyFileSync(path.join(repoRoot, file), path.join(src, file));
      }
      await git(dir, "init", "-q", "--bare", "remote.git");
      await git(dir, "init", "-q", "-b", "feat-cmux-next", src);
      await git(src, "commit", "-q", "--allow-empty", "-m", "the roll's build");
      const older = (await git(src, "rev-parse", "HEAD")).stdout.trim();
      await git(src, "commit", "-q", "--allow-empty", "-m", "a newer build");
      const newer = (await git(src, "rev-parse", "HEAD")).stdout.trim();
      // The tip as a newer roll left it: its lock pins the newer build.
      const lockPath = path.join(src, "images/cmux-vm/inputs.lock.json");
      const lock = JSON.parse(readFileSync(lockPath, "utf8")) as { programs: Array<{ name: string; version: string }> };
      for (const program of lock.programs) if (program.name === "cmux-tui") program.version = newer;
      writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`);
      await git(src, "add", ".");
      await git(src, "commit", "-q", "-m", "a newer roll");
      await git(src, "remote", "add", "origin", path.join(dir, "remote.git"));
      await git(src, "push", "-q", "origin", "feat-cmux-next");
      const before = readFileSync(path.join(src, "workers/cmux-vm/wrangler.jsonc"), "utf8");
      const temp = path.join(dir, "runner-temp");
      mkdirSync(temp);
      writeFileSync(path.join(temp, "candidate.json"), JSON.stringify(candidate));
      writeFileSync(path.join(temp, "message.txt"), "cmux-vm: image roll test\n");
      const out = await runChild(
        "bash",
        ["images/cmux-vm/image-roll-push.sh", "roll", "--candidate", path.join(temp, "candidate.json"), "--revision", "ci-4242-2", "--run", "4242",
          "--attempt", "2", "--pin", older, "--message-file", path.join(temp, "message.txt"), "--dry-run"],
        { cwd: src, env: { ...gitEnv, RUNNER_TEMP: temp, GITHUB_OUTPUT: path.join(temp, "output") } },
      );
      expect(out.status).toBe(0);
      expect(out.stdout.trim().split("\n").at(-1)).toMatch(/^nothing cmux-tui [0-9a-f]{12} is older than the tip's pinned/);
      expect(readFileSync(path.join(temp, "output"), "utf8")).toContain("result=nothing");
      expect(readFileSync(path.join(src, "workers/cmux-vm/wrangler.jsonc"), "utf8")).toBe(before);
      const pinnedNow = (JSON.parse(readFileSync(lockPath, "utf8")) as typeof lock).programs.find((p) => p.name === "cmux-tui")!.version;
      expect(pinnedNow).toBe(newer);
    }), 60_000);

  // Roll 44956612935 (2026-11-21): the checkout's single full-history fetch got an HTTP 408 and promote failed; a
  // retried blobless fetch after a shallow checkout gives the never-older check the same history.
  test("the promote job fetches full history for the never-older check, with retries", () => {
    const { YAML } = (globalThis as unknown as { Bun: { YAML: { parse(text: string): unknown } } }).Bun;
    const roll = YAML.parse(readFileSync(new URL("../../.github/workflows/cloud-vm-image-roll.yml", import.meta.url), "utf8")) as { jobs: Record<string, { steps: Array<{ name?: string; run?: string; uses?: string; with?: Record<string, unknown> }> }> };
    const steps = roll.jobs["promote"]!.steps;
    // This repository's checkout (a reused-workspace cleanup step may come before it; cmux-platform's come after).
    const own = steps.findIndex((s) => s.uses?.startsWith("actions/checkout@") && !s.with?.repository);
    const fetch = steps.findIndex((s) => s.run?.includes("--filter=blob:none") && s.run.includes("refs/heads/feat-cmux-next"));
    expect(fetch).toBeGreaterThan(own);
    expect(steps[fetch]!.run).toContain("for try in 1 2 3");
    expect(steps[fetch]!.run).toContain("--unshallow");
  });

  // Production, 2026-11-20: cmux-platform's pin was an auto-rolled id a roll trimmed (image_withdrawn). Every step that
  // writes VM_BOOT_IMAGES (the roll's promote, cmux-vm.yml's rollback) reads cmux-platform's root wrangler.jsonc first,
  // with no condition, and hands it to image-roll-push.sh, so approve and rollback keep each pinned image listed.
  test("the roll and the rollback read cmux-platform's pins and keep them", () => {
    const { YAML } = (globalThis as unknown as { Bun: { YAML: { parse(text: string): unknown } } }).Bun;
    type Step = { name?: string; id?: string; if?: string; uses?: string; run?: string; with?: Record<string, unknown> };
    const load = (name: string) => YAML.parse(readFileSync(new URL(`../../.github/workflows/${name}`, import.meta.url), "utf8")) as { jobs: Record<string, { steps: Step[] }> };
    const jobs: Array<[string, Step[]]> = [["cloud-vm-image-roll.yml promote", load("cloud-vm-image-roll.yml").jobs["promote"]!.steps]];
    for (const [name, job] of Object.entries(load("cmux-vm.yml").jobs)) if (job.steps?.some((s) => s.run?.includes("image-roll-push.sh rollback"))) jobs.push([`cmux-vm.yml ${name}`, job.steps]);
    expect(jobs.length).toBeGreaterThanOrEqual(2);
    for (const [name, steps] of jobs) {
      const pins = steps.findIndex((s) => s.uses?.startsWith("actions/checkout@") && s.with?.repository === "manaflow-ai/cmux-platform" && s.with?.path === "cmux-platform-pins");
      // A checkout of cmux-platform into cmux-platform-pins.
      expect({ name, hasPinsCheckout: pins > -1 }).toEqual({ name, hasPinsCheckout: true });
      const step = steps[pins]!;
      expect(String(step.with?.["sparse-checkout"]).split("\n").map((l) => l.trim())).toContain("wrangler.jsonc");
      const push = steps.findIndex((s) => /image-roll-push\.sh (roll|rollback)/.test(s.run ?? ""));
      expect({ name, pushAfterPins: push > pins }).toEqual({ name, pushAfterPins: true });
      expect({ name, run: steps[push]!.run }).toMatchObject({ name, run: expect.stringContaining('--platform-wrangler "$GITHUB_WORKSPACE/cmux-platform-pins/wrangler.jsonc"') });
      // The pins are read whenever the push runs: the checkout's condition is the push step's, or none.
      expect({ name, if: step.if ?? steps[push]!.if }).toEqual({ name, if: steps[push]!.if });
      // Roll 44852142963 (2026-11-20): the pr-autofix app's installation is "selected" repositories without
      // cmux-platform, so its token mint answered 404 and no roll could promote. The pins token comes from cmux-bot,
      // installed on every repository of the org, read-only and for cmux-platform alone.
      const mint = steps.find((s) => s.id === "pins-token");
      expect({ name, mint: mint?.with }).toMatchObject({
        name,
        mint: { "app-id": "${{ vars.CMUX_BOT_APP_ID }}", "private-key": "${{ secrets.CMUX_BOT_APP_KEY }}", owner: "manaflow-ai", repositories: "cmux-platform", "permission-contents": "read" },
      });
      expect({ name, keys: Object.keys(mint!.with!).filter((k) => k.startsWith("permission-")) }).toEqual({ name, keys: ["permission-contents"] });
      expect({ name, token: step.with?.token }).toEqual({ name, token: "${{ steps.pins-token.outputs.token }}" });
    }
  });

  test("the plan job checks out full history and fails on a pin it cannot fetch", () => {
    const { YAML } = (globalThis as unknown as { Bun: { YAML: { parse(text: string): unknown } } }).Bun;
    type Step = { id?: string; run?: string; with?: Record<string, unknown> };
    const roll = YAML.parse(readFileSync(new URL("../../.github/workflows/cloud-vm-image-roll.yml", import.meta.url), "utf8")) as { jobs: Record<string, { steps: Step[] }> };
    const steps = roll.jobs["plan"]!.steps as Array<Step & { uses?: string }>;
    expect(steps.find((s) => s.uses?.startsWith("actions/checkout@"))!.with).toMatchObject({ "fetch-depth": 0, filter: "blob:none" });
    const run = steps.find((s) => s.id === "plan")!.run!;
    expect(run).toContain('git fetch -q --filter=blob:none origin "$pinned"; fi');
    expect(run).not.toMatch(/--depth 1/);
  });
});

// The roll calls cloud-vm-image-bake.yml as a reusable workflow; its Freestyle key and UI test login are
// repository secrets, which reach a called workflow only when passed.
describe("auto-roll bake secrets", () => {
  const { YAML } = (globalThis as unknown as { Bun: { YAML: { parse(text: string): unknown } } }).Bun;
  type Workflow = {
    on: { workflow_call: { inputs: Record<string, unknown>; secrets: Record<string, unknown> } };
    jobs: Record<string, { secrets?: Record<string, string>; steps: Array<{ name?: string; run?: string }> }>;
  };
  const load = (name: string) => YAML.parse(readFileSync(new URL(`../../.github/workflows/${name}`, import.meta.url), "utf8")) as Workflow;
  const NAMES = ["FREESTYLE_API_KEY", "CMUX_UITEST_STACK_EMAIL", "CMUX_UITEST_STACK_PASSWORD"];

  test("the bake declares exactly the three secrets, all optional, and the roll passes exactly those", () => {
    const call = load("cloud-vm-image-bake.yml").on.workflow_call;
    expect(Object.keys(call.secrets).sort()).toEqual([...NAMES].sort());
    for (const name of NAMES) expect(call.secrets[name]).toEqual({ required: false });
    const bake = load("cloud-vm-image-roll.yml").jobs["bake"]!;
    expect(bake.secrets).toEqual(Object.fromEntries(NAMES.map((n) => [n, `\${{ secrets.${n} }}`])));
  });

  test("prod-copy still refuses when called: workflow_call has no dev_snapshot, and the input check rejects an empty one", async () => {
    const bakeWorkflow = load("cloud-vm-image-bake.yml");
    expect(bakeWorkflow.on.workflow_call.inputs).not.toHaveProperty("dev_snapshot");
    const check = bakeWorkflow.jobs["bake"]!.steps.find((s) => s.name === "Check the production copy inputs")!;
    const r = await runChild("bash", ["-c", check.run!], {
      env: { PATH: process.env["PATH"], GITHUB_REF: "refs/heads/feat-cmux-next", DEV_SNAPSHOT: "", FLAG_INPUTS: "", HAS_KEY: "yes", HAS_EMAIL: "yes", HAS_PASSWORD: "yes" },
    });
    expect(r.status).toBe(1);
    expect(r.stdout).toContain("dev_snapshot must be the dev image's snapshot id");
  });
});
