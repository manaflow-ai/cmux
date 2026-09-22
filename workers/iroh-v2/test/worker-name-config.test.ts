import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

test("v2 Worker names use the product name and preserve old names only as aliases", async () => {
  const config = JSON.parse(await readFile(join(import.meta.dir, "../wrangler.jsonc"), "utf8"));
  expect(config.name).toBe("cmux-v2-local");
  expect(config.env.development.name).toBe("cmux-v2-development");
  expect(config.env.staging.name).toBe("cmux-v2-staging");
  expect(config.env.production.name).toBe("cmux-v2");
  const alias = await readFile(join(import.meta.dir, "../aliases/index.ts"), "utf8");
  expect(alias).toContain("env.CANONICAL.fetch(request)");
});
