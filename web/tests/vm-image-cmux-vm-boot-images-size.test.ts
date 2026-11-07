import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { AUTO_PREFIX, KEEP_AUTO, locate, rolledImage, SERVICES } from "../../images/cmux-vm/auto-roll";

// Cloudflare refuses a Worker text binding over 5.1 kB (error 10054), and a refused upload fails the whole cmux-vm deploy.
// On 2026-11-07 the image roll's auto entries took staging's list to 6.0 kB, and every staging deploy failed from then on.
const TEXT_BINDING_LIMIT_BYTES = 5_100;

const wrangler = readFileSync(new URL("../../workers/cmux-vm/wrangler.jsonc", import.meta.url), "utf8");

describe("cmux-vm VM_BOOT_IMAGES stays under Cloudflare's text binding limit", () => {
  for (const env of ["staging", "production"] as const) {
    test(`${env}: with the roll's full KEEP_AUTO auto entries, the list still fits`, () => {
      const hand = locate(wrangler, env).images.filter((e) => !e.id.startsWith(AUTO_PREFIX));
      // KEEP_AUTO of the largest entries a roll can write here, as approve() writes them: the longest run id and attempt
      // rolledImage accepts, the revision ci-<run>-<attempt> the roll passes it, and this environment's services.
      const auto = Array.from({ length: KEEP_AUTO }, (_, i) => {
        const run = `${i + 1}`.padStart(20, "9");
        const entry = rolledImage({ snapshot_id: `sh-${"f".repeat(32)}`, lock_sha256: "", run: 0 }, `ci-${run}-9999`, "f".repeat(40), run, "9999");
        return { ...entry, services: [...SERVICES[env]] };
      });
      const bytes = new TextEncoder().encode(JSON.stringify([...hand, ...auto])).length;
      expect({ env, bytes, fits: bytes <= TEXT_BINDING_LIMIT_BYTES }).toEqual({ env, bytes, fits: true });
    });
  }
});
