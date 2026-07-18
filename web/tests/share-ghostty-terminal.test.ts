import { describe, expect, test } from "bun:test";
import {
  GhosttyTerminalRenderer,
  sanitizeGhosttyHtml,
  type GhosttySurfaceHandle,
  type GhosttyTerminalRuntime,
  type RenderedGhosttyTerminal,
} from "../services/share/ghosttyTerminal";
import type { TerminalVtFrame } from "../services/share/protocol";

const SURFACE_ID = "72C552A7-8F75-4DF3-AC47-3750D01D0C18";

function frame(overrides: Partial<TerminalVtFrame> = {}): TerminalVtFrame {
  return {
    surfaceId: SURFACE_ID,
    generation: 1,
    stateSeq: 1,
    columns: 80,
    rows: 24,
    kind: "snapshot",
    dataB64: "SGVsbG8=",
    ...overrides,
  };
}

class FakeSurface implements GhosttySurfaceHandle {
  readonly writes: Uint8Array[] = [];
  disposed = false;

  write(data: Uint8Array): void {
    this.writes.push(data);
  }

  render(metadata: Omit<RenderedGhosttyTerminal, "html" | "background" | "foreground" | "cursor">): RenderedGhosttyTerminal {
    return {
      ...metadata,
      html: `<div style="font-family: monospace; white-space: pre;">${this.writes.length}</div>`,
      background: "#101114",
      foreground: "#f3f4f6",
      cursor: null,
    };
  }

  dispose(): void {
    this.disposed = true;
  }
}

class FakeRuntime implements GhosttyTerminalRuntime {
  readonly surfaces: FakeSurface[] = [];

  createSurface(): FakeSurface {
    const surface = new FakeSurface();
    this.surfaces.push(surface);
    return surface;
  }
}

describe("shared libghostty terminal", () => {
  test("feeds a snapshot and contiguous patches into one terminal", async () => {
    const runtime = new FakeRuntime();
    const renderer = new GhosttyTerminalRenderer(async () => runtime);
    const snapshot = await renderer.apply(frame());
    const patch = await renderer.apply(frame({ kind: "patch", stateSeq: 2, dataB64: "IQ==" }));

    expect(snapshot.status).toBe("rendered");
    expect(patch.status).toBe("rendered");
    expect(runtime.surfaces).toHaveLength(1);
    expect(new TextDecoder().decode(runtime.surfaces[0]!.writes[0])).toBe("Hello");
    expect(new TextDecoder().decode(runtime.surfaces[0]!.writes[1])).toBe("!");
  });

  test("waits for a newer snapshot after a patch gap", async () => {
    const runtime = new FakeRuntime();
    const renderer = new GhosttyTerminalRenderer(async () => runtime);
    await renderer.apply(frame());

    expect(await renderer.apply(frame({ kind: "patch", stateSeq: 3 }))).toEqual({
      status: "resync",
      surfaceId: SURFACE_ID,
    });
    expect(await renderer.apply(frame({ kind: "patch", stateSeq: 2 }))).toEqual({ status: "waiting" });
    expect((await renderer.apply(frame({ generation: 2, stateSeq: 4 }))).status).toBe("rendered");
    expect(runtime.surfaces).toHaveLength(2);
    expect(runtime.surfaces[0]!.disposed).toBe(true);
  });

  test("ignores stale snapshots without replacing the current generation", async () => {
    const runtime = new FakeRuntime();
    const renderer = new GhosttyTerminalRenderer(async () => runtime);
    await renderer.apply(frame({ generation: 3, stateSeq: 8 }));
    expect(await renderer.apply(frame({ generation: 2, stateSeq: 9 }))).toEqual({ status: "ignored" });
    expect(runtime.surfaces).toHaveLength(1);
  });

  test("keeps Ghostty styles but makes terminal hyperlinks and unknown tags inert", () => {
    const html = '<div style="font-family: monospace; white-space: pre; color: var(--vt-palette-1); position: fixed;">' +
      '<a href="javascript:alert(1)">safe text</a><img src=x onerror=alert(1)></div>';
    const palette = Array.from({ length: 256 }, () => "#000000");
    palette[1] = "#abcdef";
    const sanitized = sanitizeGhosttyHtml(html, palette);

    expect(sanitized).toContain("font-family: monospace;");
    expect(sanitized).toContain("color: #abcdef;");
    expect(sanitized).toContain("<span>safe text</span>");
    expect(sanitized).toContain("&lt;img src=x onerror=alert(1)&gt;");
    expect(sanitized).not.toContain("href=");
    expect(sanitized).not.toContain("position:");
    expect(sanitized).not.toContain("<img");
  });
});
