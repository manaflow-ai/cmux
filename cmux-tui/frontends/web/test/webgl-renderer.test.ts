import type { ITerminalAddon } from "@xterm/xterm";
import { describe, expect, it, vi } from "vitest";
import { retagWebglDisplayP3, tryLoadWebglRenderer } from "../src/lib/webglRenderer";

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

describe("retagWebglDisplayP3", () => {
  const hostWith = (canvas: HTMLCanvasElement | null) => document.createElement("div");

  const fakeCanvas = (gl: object | null) =>
    ({ getContext: vi.fn(() => gl) }) as unknown as HTMLCanvasElement;

  it("returns null when the addon rendered no canvas (DOM fallback)", () => {
    expect(retagWebglDisplayP3(hostWith(null), () => null)).toBeNull();
  });

  it("returns null when the browser has no drawingBufferColorSpace", () => {
    const canvas = fakeCanvas({});
    expect(retagWebglDisplayP3(hostWith(canvas), () => canvas)).toBeNull();
  });

  it("retags the existing context and reports the ACTUAL buffer color space", () => {
    const gl = { drawingBufferColorSpace: "srgb" };
    const canvas = fakeCanvas(gl);
    expect(retagWebglDisplayP3(hostWith(canvas), () => canvas)).toBe("display-p3");
    expect(gl.drawingBufferColorSpace).toBe("display-p3");
  });

  it("reports srgb when the assignment is silently ignored (unsupported space)", () => {
    // Per spec, assigning an unsupported color space leaves the value unchanged.
    const gl = {
      get drawingBufferColorSpace() {
        return "srgb";
      },
      set drawingBufferColorSpace(_v: string) {},
    };
    const canvas = fakeCanvas(gl);
    expect(retagWebglDisplayP3(hostWith(canvas), () => canvas)).toBe("srgb");
  });
});
