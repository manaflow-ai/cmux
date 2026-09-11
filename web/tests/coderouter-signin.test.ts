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

  test("renders Stack Auth as a blocking route instead of an empty instant shell", () => {
    const appRoot = resolve(
      fileURLToPath(new URL(".", import.meta.url)),
      "../app/handler",
    );
    const page = readFileSync(resolve(appRoot, "[...stack]/page.tsx"), "utf8");
    const layout = readFileSync(resolve(appRoot, "layout.tsx"), "utf8");

    expect(page).toContain("export const instant = false");
    expect(layout).toContain("export const instant = false");
    expect(layout).not.toContain("<Suspense");
  });
});
