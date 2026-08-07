import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

describe("coderouter sign-in privacy", () => {
  test("uses passwordless email instead of the broad shared Google connector", () => {
    const source = readFileSync(
      resolve(
        fileURLToPath(new URL(".", import.meta.url)),
        "../app/handler/[...stack]/page.tsx",
      ),
      "utf8",
    );
    expect(source).toContain("coderouterHost");
    expect(source).toContain("<MagicLinkSignIn />");
    expect(source).toContain("Drive, Gmail, and Calendar");
  });
});
