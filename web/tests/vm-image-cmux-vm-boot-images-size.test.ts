import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { AUTO_PREFIX, KEEP_AUTO, rolledImage } from "../../images/cmux-vm/auto-roll";

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
      // KEEP_AUTO of the largest entries a roll can write: the longest run id and attempt rolledImage accepts, and the
      // revision ci-<run>-<attempt> the roll passes it.
      const auto = Array.from({ length: KEEP_AUTO }, (_, i) => {
        const run = `${i + 1}`.padStart(20, "9");
        return rolledImage({ snapshot_id: `sh-${"f".repeat(32)}`, lock_sha256: "", run: 0 }, `ci-${run}-9999`, "f".repeat(40), run, "9999");
      });
      const bytes = new TextEncoder().encode(JSON.stringify([...hand, ...auto])).length;
      expect({ line, bytes, fits: bytes <= TEXT_BINDING_LIMIT_BYTES }).toEqual({ line, bytes, fits: true });
    }
  });
});
