import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  AUTO_PREFIX,
  KEEP_AUTO,
  approve,
  locate,
  modeOf,
  rollback,
  rolledImage,
  type BootImage,
} from "../../images/cmux-vm/auto-roll";

// images/cmux-vm/auto-roll.ts edits the checked-in workers/cmux-vm/wrangler.jsonc; these run on that file.
const wrangler = readFileSync(new URL("../../workers/cmux-vm/wrangler.jsonc", import.meta.url), "utf8");
const candidate = { snapshot_id: `sh-${"a".repeat(32)}`, lock_sha256: "0".repeat(64), run: 1 };
const tui = "1234567890abcdef1234567890abcdef12345678";
const entry = (run: string): BootImage => rolledImage(candidate, `ci-${run}-1`, tui, run);

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
    expect(prod[0]!.id).toBe(`${AUTO_PREFIX}12345678-100`);
  });

  test("keeps only the newest auto-rolled entries and never trims a hand-approved one", () => {
    let text = wrangler;
    for (let run = 1; run <= KEEP_AUTO + 3; run++) text = approve(text, entry(String(run))).text;
    const prod = locate(text, "production").images;
    const staging = locate(text, "staging").images;
    const autoIds = (list: BootImage[]) => list.filter((i) => i.id.startsWith(AUTO_PREFIX)).map((i) => i.id);
    const newest = Array.from({ length: KEEP_AUTO }, (_, i) => `${AUTO_PREFIX}12345678-${KEEP_AUTO + 3 - i}`);
    expect(autoIds(prod)).toEqual(newest);
    expect(autoIds(staging)).toEqual([...newest].reverse());
    const hand = (list: BootImage[]) => list.filter((i) => !i.id.startsWith(AUTO_PREFIX));
    expect(hand(prod)).toEqual(locate(wrangler, "production").images);
    expect(hand(staging)).toEqual(locate(wrangler, "staging").images);
  });

  test("refuses an id that is already approved", () => {
    const { text } = approve(wrangler, entry("7"));
    expect(() => approve(text, entry("7"))).toThrow(/already approved/);
  });

  test("refuses a list the Worker would reject (more than 32 entries)", () => {
    const prod = locate(wrangler, "production").images;
    const many = Array.from({ length: 32 }, (_, i) => ({ ...prod[0]!, id: `hand-${i}` }));
    const big = wrangler.replace(/("production": \{[\s\S]*?"VM_BOOT_IMAGES": )("(?:[^"\\\n]|\\.)*")/u, (_, head: string) => head + JSON.stringify(JSON.stringify(many)));
    expect(() => approve(big, entry("8"))).toThrow(/at most 32/);
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

  test("does nothing when a newer roll is already first", () => {
    let text = approve(wrangler, entry("300")).text;
    text = approve(text, entry("301")).text;
    const result = rollback(text, entry("300").id);
    expect(result.rolledBack).toBe(false);
    expect(result.text).toBe(text);
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

  test("a candidate without a snapshot id or a cmux-tui commit makes no entry", () => {
    expect(() => rolledImage({ ...candidate, snapshot_id: "" }, "ci-1-1", tui, "1")).toThrow();
    expect(() => rolledImage(candidate, "ci-1-1", "main", "1")).toThrow();
  });
});
