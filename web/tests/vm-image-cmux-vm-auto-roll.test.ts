import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  AUTO_PREFIX,
  BOOT_ENTRY,
  KEEP_AUTO,
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
  platformPins,
  replaceList,
  rollback,
  rolledImage,
  settle,
  type BootImage,
  type SettleInput,
  workerTakesLarge,
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
    expect(prod[0]).toEqual({ ...entry("100"), services: ["cloud-platform-production", "ci-product-smoke", "ci-product-smoke-platform"] });
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
        { ...FALLBACK, services: env === "production" ? ["cloud-platform-production", "ci-product-smoke", "ci-product-smoke-platform"] : ["cloud-platform-dev", "cloud-platform-staging"] },
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
    expect(prod[0]).toEqual({ ...keyed("11"), services: ["cloud-platform-production", "ci-product-smoke", "ci-product-smoke-platform"] });
    expect(prod[1]).not.toHaveProperty("inputs_sha256");
    const bad = { ...keyed("12"), inputs_sha256: "A".repeat(64) };
    expect(() => replaceList(text, "production", [bad, ...prod])).toThrow(/bad inputs_sha256/);
    expect(() => replaceList(text, "production", [{ ...entry("12"), extra: "x" } as BootImage, ...prod])).toThrow(/fields/);
  });

  // The large image (bake.ts --large): the same bake at the default Cloud chat start size, which the cmux-vm Worker
  // boots for a create that asks for exactly that size (workers/cmux-vm README, "Approved service boot images").
  const LARGE_ID = `sh-${"b".repeat(32)}`;
  const LARGE = { snapshotId: LARGE_ID, vcpus: 4, memoryMib: 16384, diskMib: 65536 };
  const largeCandidate = { ...candidate, large: { snapshot: "x-large", snapshot_id: LARGE_ID, size: { vcpu: 4, mem_gib: 16, disk_gib: 64 }, smoke: { result: "PASSED" } } };
  const withLarge = (run: string): BootImage => rolledImage(largeCandidate, `ci-${run}-1`, tui, run, "1");

  test("the entry carries the candidate's large image only when it passed its smoke and is well formed", () => {
    expect(withLarge("1").large).toEqual(LARGE);
    expect(entry("1")).not.toHaveProperty("large");
    const base = largeCandidate.large;
    for (const bad of [
      { ...base, smoke: { result: "FAILED" } },
      { ...base, smoke: undefined },
      { ...base, snapshot_id: "x-large" },
      { ...base, snapshot_id: candidate.snapshot_id },
      { ...base, size: { vcpu: 4, mem_gib: 16 } },
      { ...base, size: { vcpu: 4.5, mem_gib: 16, disk_gib: 64 } },
      "large",
    ])
      expect(rolledImage({ ...candidate, large: bad as typeof base }, "ci-1-1", tui, "1", "1")).not.toHaveProperty("large");
  });

  test("lists the large image on staging's entry only, never production's", () => {
    const { text, large } = approve(wrangler, withLarge("20"));
    expect(large).toBe(true);
    expect(locate(text, "staging").images.at(-1)).toEqual({ ...withLarge("20"), services: ["cloud-platform-dev", "cloud-platform-staging"] });
    expect(locate(text, "production").images[0]).toEqual({ ...entry("20"), services: ["cloud-platform-production", "ci-product-smoke", "ci-product-smoke-platform"] });
    expect(locate(text, "production").images.some((i) => "large" in i)).toBe(false);
    expect(approve(wrangler, entry("21")).large).toBe(false);
  });

  test("an entry that stays listed keeps its large image across later rolls, so a create journaled on it can retry", () => {
    const first = approve(wrangler, withLarge("30")).text;
    const id30 = locate(first, "staging").images.at(-1)!.id;
    // A default roll (no large image baked) must not take the older entry's away.
    const second = approve(first, entry("31")).text;
    expect(locate(second, "staging").images.find((i) => i.id === id30)?.large).toEqual(LARGE);
    const third = locate(approve(second, withLarge("32")).text, "staging").images;
    expect(third.at(-1)!.large).toEqual(LARGE);
    expect(third.find((i) => i.id === id30)?.large).toEqual(LARGE);
    expect(locate(approve(second, withLarge("32")).text, "production").images.some((i) => "large" in i)).toBe(false);
  });

  test("a large image that would put staging over the text binding limit is left out, and the roll goes on", () => {
    const staging = locate(wrangler, "staging").images;
    // Hand-approved entries are added and their names padded (100 characters at most each) until the plain roll fits
    // with 10 bytes to spare, fewer than the large image needs.
    const rolled = { ...entry("40"), services: ["cloud-platform-dev", "cloud-platform-staging"] };
    const spare = (images: BootImage[]) => MAX_BYTES - Buffer.byteLength(JSON.stringify([...images, rolled]));
    let filled = staging;
    for (let n = 0; spare([{ ...staging[0]!, id: `hand-pad-${n}`, displayName: "x" }, ...filled]) >= 10; n++)
      filled = [{ ...staging[0]!, id: `hand-pad-${n}`, displayName: "x" }, ...filled];
    let pad = spare(filled) - 10;
    expect(pad).toBeGreaterThanOrEqual(0);
    const padded = filled.map((i) => {
      const add = Math.min(pad, 100 - i.displayName.length);
      pad -= add;
      return { ...i, displayName: i.displayName + "x".repeat(add) };
    });
    expect(pad).toBe(0);
    const tight = replaceList(wrangler, "staging", padded);
    const { text, large } = approve(tight, withLarge("40"));
    expect(large).toBe(false);
    expect(locate(text, "staging").images.at(-1)).toEqual({ ...entry("40"), services: ["cloud-platform-dev", "cloud-platform-staging"] });
  });

  test("a large image is listed only beside a Worker source that takes one", () => {
    // This checkout's Worker does; a copy from before it (cmux-platform's, until its next sync) refuses the whole list.
    expect(workerTakesLarge(new URL("../../workers/cmux-vm/wrangler.jsonc", import.meta.url).pathname)).toBe(true);
    const dir = mkdtempSync(path.join(tmpdir(), "auto-roll-old-worker-"));
    try {
      expect(workerTakesLarge(path.join(dir, "wrangler.jsonc"))).toBe(false);
      mkdirSync(path.join(dir, "src/upstream"), { recursive: true });
      writeFileSync(path.join(dir, "src/upstream/live-images.ts"), "const Entry = Schema.Struct({\n  inputs_sha256: Schema.optional(Schema.Unknown),\n});\n");
      expect(workerTakesLarge(path.join(dir, "wrangler.jsonc"))).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a list with a large image reads back, and a malformed one is refused", () => {
    const { text } = approve(wrangler, withLarge("50"));
    const staging = locate(text, "staging").images;
    expect(staging.at(-1)!.large).toEqual(LARGE);
    for (const bad of [{ ...LARGE, vcpus: 0 }, { ...LARGE, snapshotId: "bad id" }, { ...LARGE, extra: 1 }, { snapshotId: LARGE_ID }, { ...LARGE, snapshotId: staging.at(-1)!.snapshotId }])
      expect(() => replaceList(text, "staging", [...staging.slice(0, -1), { ...staging.at(-1)!, large: bad as BootImage["large"] }])).toThrow(/bad large/);
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
    for (let run = 1; run <= KEEP_AUTO + 3; run++) text = approve(text, entry(String(500 + run)), [pinned.id]).text;
    for (const env of ["staging", "production"] as const) {
      expect({ env, pinned: locate(text, env).images.filter((i) => i.id === pinned.id).length }).toEqual({ env, pinned: 1 });
      // The pin does not count toward KEEP_AUTO: the newest KEEP_AUTO rolls stay too.
      expect({ env, auto: locate(text, env).images.filter((i) => i.id.startsWith(AUTO_PREFIX)).length }).toEqual({ env, auto: KEEP_AUTO + 1 });
    }
  });
  // Production, 2026-11-25 (roll 45625813906): with a pin plus KEEP_AUTO keyed rolls, the next roll's list came to
  // 5,150 bytes and approve threw, so no roll could promote. A list keeps fewer rolls until it fits.
  test("approve keeps fewer unpinned rolls when the pin and KEEP_AUTO rolls would pass MAX_BYTES", () => {
    const pinned = keyed("700");
    let text = approve(wrangler, pinned).text;
    for (let run = 1; run <= KEEP_AUTO + 8; run++) text = approve(text, keyed(String(700 + run)), [pinned.id]).text;
    const newest = keyed(String(700 + KEEP_AUTO + 8)).id;
    for (const env of ["staging", "production"] as const) {
      const images = locate(text, env).images;
      expect(Buffer.byteLength(JSON.stringify(images))).toBeLessThanOrEqual(MAX_BYTES);
      expect({ env, pinned: images.some((i) => i.id === pinned.id), newest: images.some((i) => i.id === newest) }).toEqual({ env, pinned: true, newest: true });
      expect(images.filter((i) => !i.id.startsWith(AUTO_PREFIX))).toEqual(locate(wrangler, env).images);
    }
    expect(bootedImage(text, "production")).toBe(newest);
  });
  test("approve on the 2026-11-25 production list (pin 45ed727f, six rolls) fits instead of throwing", () => {
    const pin = "cloud-native-auto-45ed727f-45133798615-1";
    if (!locate(checkedIn, "production").images.some((i) => i.id === pin)) return;
    const { text } = approve(checkedIn, keyed("45629291168"), [pin]);
    for (const env of ["staging", "production"] as const) {
      const images = locate(text, env).images;
      expect(Buffer.byteLength(JSON.stringify(images))).toBeLessThanOrEqual(MAX_BYTES);
      expect(images.some((i) => i.id === pin)).toBe(true);
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
    for (const deploy of ["cancelled", "failure", ""]) expect(settle(roll({ deploy, product: "" })).outcome).toBe("rollback");
    expect(settle(roll({ deploy: "skipped", product: "", attempt: ROLLBACK_DEPLOYS })).outcome).toBe("rollback");
    expect(settle(roll({ product: "failure" })).outcome).toBe("rollback");
    // A green create that booted some other image proves nothing about this one.
    expect(settle(roll({ bootImage: previous })).outcome).toBe("rollback");
  });

  test("a roll whose production deploy never ran (check red first) is deployed again, at most ROLLBACK_DEPLOYS deploys", () => {
    // 6fde033d-45743286480-3, 2026-11-26: the check job's checkout hung, deploy-production was skipped, and the image
    // was rolled back with production never having booted it.
    for (let attempt = 1; attempt < ROLLBACK_DEPLOYS; attempt++) {
      expect(settle(roll({ deploy: "skipped", product: "", bootImage: "", deployedFirst: image, attempt }))).toMatchObject({ outcome: "retry", nextAttempt: attempt + 1 });
    }
    expect(settle(roll({ deploy: "skipped", product: "", bootImage: "", attempt: ROLLBACK_DEPLOYS })).outcome).toBe("rollback");
    // Gone from both lists already: nothing to deploy again.
    expect(settle(roll({ deploy: "skipped", product: "", tipHas: false })).outcome).toBe("superseded");
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
    expect(retry.run).toContain('-f image_roll_redeploy="$redeploy"');
    expect(read).toContain('if [ "$IN_REDEPLOY" = true ]; then kind=roll; fi');
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

  test("the roll bakes the large image only when its dispatch asks, so a build or push roll never does", () => {
    const roll = load("cloud-vm-image-roll.yml") as unknown as { on: { workflow_dispatch: { inputs: Record<string, { type?: string; default?: unknown }> } }; jobs: { bake: { with: Record<string, unknown> } } };
    expect(roll.on.workflow_dispatch.inputs["large_image"]).toMatchObject({ type: "boolean", default: false });
    expect(roll.jobs.bake.with["large_image"]).toBe("${{ inputs.large_image == true }}");
  });

  test("a roll's image id carries the run attempt", () => {
    const roll = load("cloud-vm-image-roll.yml");
    const promote = roll.jobs["promote"]!;
    expect(stepOf(promote, "message").run).toContain('image="cloud-native-auto-${tui:0:8}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"');
    expect(stepOf(promote, "push").run).toContain('--attempt "$GITHUB_RUN_ATTEMPT"');
  });

  // Roll 44282278310 (2026-11-18): with vars.LINUX_RUNNER on a 16-vCPU Blacksmith size, plan queued 41 min and
  // promote 20+ min for that size, each a minute of work. Only the bake needs the big runner. Since #53974 froze
  // CI_DEPLOY_SKIP_FLEET to its value, each control job takes the one-job deploy JIT label by literal (#47946).
  test("the roll's control jobs take the one-job deploy JIT label, never LINUX_RUNNER or a size pool; the bake keeps its label", () => {
    const roll = load("cloud-vm-image-roll.yml") as unknown as { jobs: Record<string, { "runs-on"?: string }> };
    for (const job of ["platform-readiness", "plan", "promote", "report"]) {
      const runsOn = roll.jobs[job]!["runs-on"]!;
      expect(runsOn).not.toContain("vars.LINUX_RUNNER");
      expect(runsOn).toBe("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-deploy-jit-x64' }}");
      // report holds a contents: write token, so it runs only on a one-job VM, never a pool whose member is a
      // persistent owned label (linux_8): #51925, tests/test_ci_ephemeral_pool_readers.py.
      expect(runsOn).not.toContain("RUNNER_POOLS");
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
    // A checkout names its branch as refs/heads/X, so it fetches one branch (#51926).
    expect(checkout?.with).toMatchObject({ repository: "manaflow-ai/cmux-platform", ref: "refs/heads/main" });
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

  test("platform mode pushes Wrangler first and leaves cmux with a lock-only commit", () =>
    withDir(async (dir) => {
      const src = path.join(dir, "src");
      const platform = path.join(dir, "platform");
      for (const file of ["images/cmux-vm/auto-roll.ts", "images/cmux-vm/auto-roll.json", "images/cmux-vm/fallback-image.json", "images/cmux-vm/inputs.lock.json", "images/cmux-vm/image-roll-push.sh", "workers/cmux-vm/wrangler.jsonc"]) {
        mkdirSync(path.dirname(path.join(src, file)), { recursive: true });
        copyFileSync(path.join(repoRoot, file), path.join(src, file));
      }
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
      writeFileSync(path.join(temp, "candidate.json"), JSON.stringify({ ...candidate, lock_sha256: createHash("sha256").update(`${lock}\n`).digest("hex") }));
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
      const decided = JSON.parse(ok.stdout) as { roll: boolean; reason: string };
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

  // 2026-11-26: push rolls kept the lock's cmux-tui 99de33e5 (13:23Z) while builds to 97bd0527 were published, so the
  // 16:52Z push roll promoted the stale build again and NOW's Cloud image lag sat past its bound.
  test("a push roll pins the newest published build only when it is on the tip, newer and different", () =>
    withDir(async (dir) => {
      const full = path.join(dir, "full");
      await git(dir, "init", "-q", "-b", "feat-cmux-next", full);
      const commitOf = async (msg: string, file?: string) => {
        if (file) {
          mkdirSync(path.dirname(path.join(full, file)), { recursive: true });
          writeFileSync(path.join(full, file), msg);
          await git(full, "add", file);
        }
        await git(full, "commit", "-q", "--allow-empty", "-m", msg);
        return (await git(full, "rev-parse", "HEAD")).stdout.trim();
      };
      const older = await commitOf("older");
      const pinned = await commitOf("pinned");
      const newer = await commitOf("newer");
      const before = await commitOf("before");
      await commitOf("image change", "images/cmux-vm/x.txt");
      await git(full, "checkout", "-q", "-b", "lane", before);
      const offTip = await commitOf("lane build");
      await git(full, "checkout", "-q", "feat-cmux-next");
      const tip = (await git(full, "rev-parse", "HEAD")).stdout.trim();
      const lock = path.join(dir, "lock.json");
      writeFileSync(lock, JSON.stringify({ programs: [{ name: "cmux-tui", version: pinned }] }));
      const fakeBin = path.join(dir, "bin");
      mkdirSync(fakeBin);
      const realBun = (await runChildOk("bash", ["-c", "command -v bun"], { env: process.env })).stdout.trim();
      // files.cmux.com's latest manifest, as pin-cmux-tui.ts --latest prints it; LATEST=fail answers like a 503.
      // --commit SHA answers for the commits in PUBLISHED (their builds are published) and 404s for the rest.
      writeFileSync(
        path.join(fakeBin, "bun"),
        `#!/usr/bin/env bash\ncase "\${1:-}" in *pin-cmux-tui.ts)\n  if [ "\${2:-}" = --commit ]; then case " \${PUBLISHED:-} " in *" $3 "*) printf '{"commit":"%s","unchanged":false}' "$3"; exit 0;; esac; echo "$3/manifest.json: 404" >&2; exit 1; fi\n  [ "$LATEST" = fail ] && { echo "latest/manifest.json: 503" >&2; exit 1; }\n  printf '{"commit":"%s","unchanged":%s}' "$LATEST" "\${UNCHANGED:-false}"; exit 0;;\nesac\nexec ${realBun} "$@"\n`,
      );
      await runChildOk("chmod", ["+x", path.join(fakeBin, "bun")]);
      const script = path.join(repoRoot, "images/cmux-vm/auto-roll.ts");
      const plan = async (latest: string, unchanged = "false", published: string[] = []) => {
        const out = await runChildOk(path.join(fakeBin, "bun"), [script, "plan", "--event", "push", "--commit", tip, "--before", before, "--tip", "HEAD", "--lock", lock, "--repo", full], {
          env: { ...process.env, PATH: `${fakeBin}:${process.env.PATH}`, LATEST: latest, UNCHANGED: unchanged, PUBLISHED: published.join(" ") },
        });
        return JSON.parse(out.stdout) as { roll: boolean; reason: string; pin: string; cmuxTui: string };
      };

      const fresh = await plan(newer);
      expect(fresh.roll).toBe(true);
      expect(fresh.pin).toBe(newer);
      expect(fresh.cmuxTui).toBe(newer);
      expect(fresh.reason).toMatch(/newest published build/);
      for (const [latest, unchanged, why] of [
        [older, "false", /not newer/],
        [pinned, "false", /carries the pinned binaries/],
        [newer, "true", /carries the pinned binaries/],
        [offTip, "false", /not on HEAD/],
        ["fail", "false", /unreadable: .*503/],
      ] as const) {
        const kept = await plan(latest, unchanged);
        expect(kept.roll).toBe(true);
        expect(kept.pin).toBe("");
        expect(kept.cmuxTui).toBe(pinned);
        expect(kept.reason).toMatch(why);
      }

      // 2026-11-27: latest/ tracks main (3bb7a878, not on feat-cmux-next), so push rolls kept 348e8a8a while
      // feat-cmux-next builds were published. The newest published build on the tip is pinned instead.
      const onTip = await plan(offTip, "false", [older, newer]);
      expect(onTip.pin).toBe(newer);
      expect(onTip.cmuxTui).toBe(newer);
      expect(onTip.reason).toMatch(/newest build published on HEAD .*latest build .* is not on HEAD/);
      const onlyOlder = await plan(offTip, "false", [older]);
      expect(onlyOlder.pin).toBe("");
      expect(onlyOlder.cmuxTui).toBe(pinned);
      expect(onlyOlder.reason).toMatch(/not on HEAD; none of the 3 newest commits after the pin has a published build/);
    }), 60_000);

  // Push roll 45961450781 (2026-11-27 07:52Z) kept cmux-tui f7b548a5, 516 commits back: publishing lagged from 06:26Z,
  // the newest published build was 185 commits deep and only the 40 newest commits were asked.
  test("a push roll finds the newest published build past the 40 newest commits", () =>
    withDir(async (dir) => {
      const full = path.join(dir, "full");
      await git(dir, "init", "-q", "-b", "feat-cmux-next", full);
      const commitOf = async (msg: string, file?: string) => {
        if (file) {
          mkdirSync(path.dirname(path.join(full, file)), { recursive: true });
          writeFileSync(path.join(full, file), msg);
          await git(full, "add", file);
        }
        await git(full, "commit", "-q", "--allow-empty", "-m", msg);
        return (await git(full, "rev-parse", "HEAD")).stdout.trim();
      };
      const pinned = await commitOf("pinned");
      const deepOld = await commitOf("deep old build");
      const deepNew = await commitOf("deep new build");
      for (let i = 0; i < 60; i++) await commitOf(`unbuilt ${i}`);
      const before = await commitOf("before");
      await commitOf("image change", "images/cmux-vm/x.txt");
      const tip = (await git(full, "rev-parse", "HEAD")).stdout.trim();
      await git(full, "checkout", "-q", "-b", "main-only", pinned);
      const mainBuild = await commitOf("main build");
      await git(full, "checkout", "-q", "feat-cmux-next");
      const lock = path.join(dir, "lock.json");
      writeFileSync(lock, JSON.stringify({ programs: [{ name: "cmux-tui", version: pinned }] }));
      const fakeBin = path.join(dir, "bin");
      mkdirSync(fakeBin);
      const realBun = (await runChildOk("bash", ["-c", "command -v bun"], { env: process.env })).stdout.trim();
      writeFileSync(
        path.join(fakeBin, "bun"),
        `#!/usr/bin/env bash\ncase "\${1:-}" in *pin-cmux-tui.ts)\n  if [ "\${2:-}" = --commit ]; then case " \${PUBLISHED:-} " in *" $3 "*) printf '{"commit":"%s","unchanged":false}' "$3"; exit 0;; esac; echo "$3/manifest.json: 404" >&2; exit 1; fi\n  printf '{"commit":"%s","unchanged":false}' "$LATEST"; exit 0;;\nesac\nexec ${realBun} "$@"\n`,
      );
      await runChildOk("chmod", ["+x", path.join(fakeBin, "bun")]);
      const script = path.join(repoRoot, "images/cmux-vm/auto-roll.ts");
      const out = await runChildOk(path.join(fakeBin, "bun"), [script, "plan", "--event", "push", "--commit", tip, "--before", before, "--tip", "HEAD", "--lock", lock, "--repo", full], {
        env: { ...process.env, PATH: `${fakeBin}:${process.env.PATH}`, LATEST: mainBuild, PUBLISHED: [deepOld, deepNew].join(" ") },
      });
      const plan = JSON.parse(out.stdout) as { roll: boolean; reason: string; pin: string; cmuxTui: string };
      expect(plan.roll).toBe(true);
      expect(plan.pin).toBe(deepNew);
      expect(plan.cmuxTui).toBe(deepNew);
      expect(plan.reason).toMatch(/newest build published on HEAD/);
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

  // Rolls 45180251986 and 45200355313 (2026-11-23): plan's checkout with fetch-depth 0 fetched every branch and
  // tag, which stalled under 1000 B/s three times ("bad pack header"), so no roll got past plan. Like promote,
  // plan checks out the tip shallow and fetches only feat-cmux-next's history without blobs, with retries.
  test("the plan job fetches feat-cmux-next's full history alone, with retries, and fails on a pin it cannot fetch", () => {
    const { YAML } = (globalThis as unknown as { Bun: { YAML: { parse(text: string): unknown } } }).Bun;
    type Step = { id?: string; name?: string; run?: string; with?: Record<string, unknown> };
    const roll = YAML.parse(readFileSync(new URL("../../.github/workflows/cloud-vm-image-roll.yml", import.meta.url), "utf8")) as { jobs: Record<string, { steps: Step[] }> };
    const steps = roll.jobs["plan"]!.steps as Array<Step & { uses?: string }>;
    const own = steps.findIndex((s) => s.uses?.startsWith("actions/checkout@"));
    expect(steps[own]!.with?.["fetch-depth"]).toBeUndefined();
    const fetch = steps.findIndex((s) => s.run?.includes("--filter=blob:none") && s.run.includes("+refs/heads/feat-cmux-next:refs/remotes/origin/feat-cmux-next"));
    expect(fetch).toBeGreaterThan(own);
    expect(fetch).toBeLessThan(steps.findIndex((s) => s.id === "plan"));
    expect(steps[fetch]!.run).toContain("--no-tags");
    expect(steps[fetch]!.run).toContain("for try in 1 2 3");
    expect(steps[fetch]!.run).not.toContain("refs/heads/*");
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
  // The private R2 copy of a kept image (#53777): optional, and the roll uploads its own copy, so it passes none.
  const R2 = ["CF_R2_ACCESS_KEY_ID", "CF_R2_SECRET_ACCESS_KEY", "CF_R2_ACCOUNT_ID"];

  test("the bake declares the three secrets and the R2 ones, all optional, and the roll passes exactly the three", () => {
    const call = load("cloud-vm-image-bake.yml").on.workflow_call;
    expect(Object.keys(call.secrets).sort()).toEqual([...NAMES, ...R2].sort());
    for (const name of [...NAMES, ...R2]) expect(call.secrets[name]).toEqual({ required: false });
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
