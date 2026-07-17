import type { ITerminalAddon } from "@xterm/xterm";
import { describe, expect, it, vi } from "vitest";
import { tryLoadWebglRenderer } from "../src/lib/webglRenderer";

vi.mock("@xterm/addon-webgl", () => ({
  WebglAddon: class {
    activate() {}
    dispose() {}
  },
}));

describe("xterm WebGL renderer", () => {
  it("loads and returns an addon for explicit cleanup", () => {
    const addon = { activate: vi.fn(), dispose: vi.fn() } satisfies ITerminalAddon;
    const terminal = { loadAddon: vi.fn() };

    expect(tryLoadWebglRenderer(terminal, () => addon)).toBe(addon);
    expect(terminal.loadAddon).toHaveBeenCalledWith(addon);
  });

  it("silently falls back and disposes after context activation fails", () => {
    const addon = { activate: vi.fn(), dispose: vi.fn() } satisfies ITerminalAddon;
    const terminal = { loadAddon: vi.fn(() => { throw new Error("WebGL unavailable"); }) };

    expect(tryLoadWebglRenderer(terminal, () => addon)).toBeNull();
    expect(addon.dispose).toHaveBeenCalledOnce();
  });

  it("silently falls back when addon construction fails", () => {
    const terminal = { loadAddon: vi.fn() };
    const create = () => { throw new Error("No WebGL context"); };

    expect(tryLoadWebglRenderer(terminal, create)).toBeNull();
    expect(terminal.loadAddon).not.toHaveBeenCalled();
  });
});
