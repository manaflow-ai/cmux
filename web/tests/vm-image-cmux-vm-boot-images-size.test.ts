import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { AUTO_PREFIX, KEEP_AUTO } from "../../images/cmux-vm/auto-roll";

// Cloudflare refuses a Worker text binding over 5.1 kB (error 10054), and a refused upload fails the whole cmux-vm deploy.
// On 2026-11-07 the image roll's auto entries took staging's list to 6.0 kB, and every staging deploy failed from then on.
const TEXT_BINDING_LIMIT_BYTES = 5_100;

const wrangler = readFileSync(new URL("../../workers/cmux-vm/wrangler.jsonc", import.meta.url), "utf8");
const lists = [...wrangler.matchAll(/"VM_BOOT_IMAGES":\s*"((?:[^"\\]|\\.)*)"/g)].map((m) => {
  const raw = JSON.parse(`"${m[1]}"`) as string;
  return { line: wrangler.slice(0, m.index).split("\n").length, entries: JSON.parse(raw) as Array<Record<string, unknown> & { id: string }> };
});

describe("cmux-vm VM_BOOT_IMAGES stays under Cloudflare's text binding limit", () => {
  test("every environment lists boot images", () => {
    expect(lists.length).toBeGreaterThanOrEqual(2);
  });

  test("with the roll's full KEEP_AUTO auto entries, each list still fits", () => {
    for (const { line, entries } of lists) {
      const hand = entries.filter((e) => !e.id.startsWith(AUTO_PREFIX));
      // The largest auto entry a roll writes for this list (or the largest entry here), repeated KEEP_AUTO times with
      // the longest id a roll names: cloud-native-auto-<8 hex>-<11-digit run>-<attempt>.
      const sample = entries.find((e) => e.id.startsWith(AUTO_PREFIX)) ?? entries[entries.length - 1];
      const auto = Array.from({ length: KEEP_AUTO }, (_, i) => ({ ...sample, id: `${AUTO_PREFIX}ffffffff-99999999999-${i + 1}` }));
      const bytes = new TextEncoder().encode(JSON.stringify([...hand, ...auto])).length;
      expect({ line, bytes, fits: bytes <= TEXT_BINDING_LIMIT_BYTES }).toEqual({ line, bytes, fits: true });
    }
  });
});
