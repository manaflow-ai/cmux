import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";

describe("bundled libghostty-vt notices", () => {
  test("ships every notice and pins each source", async () => {
    const publicDirectory = new URL("../public/", import.meta.url);
    const notices = await readFile(new URL("ghostty-vt.NOTICES", publicDirectory), "utf8");
    const provenance = JSON.parse(
      await readFile(new URL("ghostty-vt.provenance.json", publicDirectory), "utf8"),
    ) as {
      commit?: string;
      notices?: string;
      components?: Array<{ name?: string; source?: string }>;
    };

    expect(provenance.commit).toBe("0d515313aea4ae358f22a4c7e462423a6ea4bbdd");
    expect(provenance.notices).toBe("ghostty-vt.NOTICES");
    expect(provenance.components?.map((component) => component.name)).toEqual([
      "uucode",
      "Unicode Character Database",
      "Bjoern Hoehrmann UTF-8 decoder",
    ]);
    expect(notices).toContain("Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors");
    expect(notices).toContain("Copyright (c) 2026 Jacob Sandlund");
    expect(notices).toContain("Copyright (c) 2008-2009 Bjoern Hoehrmann");
    expect(notices).toContain("Copyright © 1991-2025 Unicode, Inc.");
    expect(notices).toContain("0d515313aea4ae358f22a4c7e462423a6ea4bbdd");
    expect(notices).toContain("54d650cf37948552f0c3d8168903e5e8a16901b8");
    expect(notices).toContain("https://www.unicode.org/license.txt");
    expect(notices).toContain("https://bjoern.hoehrmann.de/utf-8/decoder/dfa/");
  });
});
