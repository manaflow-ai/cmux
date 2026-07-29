import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const appDir = join(dirname(fileURLToPath(import.meta.url)), "..", "app");

describe("Next app route layout invariants", () => {
  test("keeps html and body in the root layout so API routes stay registered", async () => {
    const rootLayout = await readFile(join(appDir, "layout.tsx"), "utf8");
    const localizedLayout = await readFile(join(appDir, "[locale]", "layout.tsx"), "utf8");
    const handlerLayout = await readFile(join(appDir, "handler", "layout.tsx"), "utf8");

    expect(rootLayout).toContain("<html");
    expect(rootLayout).toContain("<body");
    expect(rootLayout).toContain("x-next-intl-locale");
    expect(rootLayout).toContain("lang={locale}");
    expect(rootLayout).toContain("dir={dir}");
    expect(localizedLayout).not.toContain("<html");
    expect(localizedLayout).not.toContain("<body");
    expect(handlerLayout).not.toContain("<html");
    expect(handlerLayout).not.toContain("<body");
  });
});
