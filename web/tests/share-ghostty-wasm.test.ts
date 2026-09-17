import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import {
  GHOSTTY_WASM_SHA256,
  ghosttyWasmAssetURL,
  instantiateGhosttyRuntime,
} from "../services/share/ghosttyTerminal";
import { MAX_LIVE_TERMINAL_SURFACES } from "../services/share/terminalLimits";

describe("bundled libghostty-vt", () => {
  test("parses VT with the current ABI and renders inert Ghostty HTML", async () => {
    const bytes = await readFile(new URL("../public/ghostty-vt.wasm", import.meta.url));
    expect(createHash("sha256").update(bytes).digest("hex")).toBe(GHOSTTY_WASM_SHA256);
    expect(ghosttyWasmAssetURL()).toBe(`/ghostty-vt.wasm?v=${GHOSTTY_WASM_SHA256}`);
    const wasmBytes = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    const runtime = await instantiateGhosttyRuntime(wasmBytes);
    const surface = runtime.createSurface(40, 4);
    try {
      surface.write(new TextEncoder().encode(
        "hello \u001b[1;32mghostty\u001b[0m\r\n" +
        "\u001b]8;;javascript:alert(1)\u001b\\safe link\u001b]8;;\u001b\\",
      ));
      const metadata = {
        surfaceId: "72C552A7-8F75-4DF3-AC47-3750D01D0C18",
        generation: 1,
        stateSeq: 1,
        columns: 40,
        rows: 4,
      } as const;
      const rendered = surface.render(metadata);

      expect(rendered.html).toContain("hello");
      expect(rendered.html).toContain("ghostty");
      expect(rendered.html).toContain("font-weight: bold;");
      expect(rendered.html).toContain("font-family: inherit;");
      expect(rendered.html).not.toContain("font-family: monospace;");
      expect(rendered.html).toContain("<span>safe link</span>");
      expect(rendered.html).not.toContain("href=");
      expect(rendered.background).toMatch(/^#[0-9a-f]{6}$/u);
      expect(rendered.foreground).toMatch(/^#[0-9a-f]{6}$/u);
      expect(rendered.cursor).not.toBeNull();

      surface.write(new TextEncoder().encode("\u001b[1;1Hupdated"));
      const patched = surface.render({ ...metadata, stateSeq: 2 });
      expect(patched.html).toContain("updated");
      expect(patched.stateSeq).toBe(2);
    } finally {
      surface.dispose();
    }

    expect(() => runtime.createSurface(501, 400)).toThrow("ghostty_terminal_dimensions_exceeded");
    const liveSurfaces = Array.from({ length: MAX_LIVE_TERMINAL_SURFACES }, () => runtime.createSurface(1, 1));
    try {
      expect(() => runtime.createSurface(1, 1)).toThrow("ghostty_terminal_capacity_exceeded");
    } finally {
      for (const liveSurface of liveSurfaces) liveSurface.dispose();
    }
  });
});
