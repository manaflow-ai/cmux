import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const messagesDirectory = resolve(
  fileURLToPath(new URL(".", import.meta.url)),
  "../messages",
);

describe("CodeRouter branding", () => {
  test("does not expose the retired Subrouter name in localized copy", () => {
    for (const file of readdirSync(messagesDirectory)) {
      if (!file.endsWith(".json")) continue;
      const source = readFileSync(resolve(messagesDirectory, file), "utf8");
      expect(source.toLowerCase()).not.toContain("subrouter");
    }
  });
});
