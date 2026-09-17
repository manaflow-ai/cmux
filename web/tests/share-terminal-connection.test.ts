import { describe, expect, test } from "bun:test";
import {
  applyTerminalFrameInScene,
  terminalVtSurfaceIdsForScene,
} from "../app/share/[shareId]/ShareWorkspaceConnection";
import type { TerminalApplyResult } from "../services/share/ghosttyTerminal";
import type { TerminalVtFrame, WorkspaceScene } from "../services/share/protocol";

const frame: TerminalVtFrame = {
  surfaceId: "72C552A7-8F75-4DF3-AC47-3750D01D0C18",
  generation: 1,
  stateSeq: 1,
  columns: 80,
  rows: 24,
  kind: "snapshot",
  dataB64: "SGVsbG8=",
};

describe("shared terminal scene authorization", () => {
  test("authorizes terminal VT for terminal and TextBox scene surfaces", () => {
    const scene: WorkspaceScene = {
      workspaceId: "workspace",
      workspaceTitle: "Workspace",
      layoutRevision: 1,
      width: 1_000,
      height: 700,
      panes: [{
        id: "pane",
        frame: { x: 0, y: 0, width: 1_000, height: 700 },
        selectedSurfaceId: frame.surfaceId,
        surfaces: [
          { id: "terminal-surface", title: "Terminal", kind: "terminal" },
          { id: frame.surfaceId, title: "TextBox", kind: "textbox", docId: frame.surfaceId },
          { id: "browser-surface", title: "Browser", kind: "browser" },
        ],
      }],
    };

    expect([...terminalVtSurfaceIdsForScene(scene)]).toEqual(["terminal-surface", frame.surfaceId]);
  });

  test("never invokes the renderer before or outside an authoritative scene", async () => {
    let applyCalls = 0;
    const renderer = {
      apply: async (): Promise<TerminalApplyResult> => {
        applyCalls += 1;
        return { status: "ignored" };
      },
    };

    expect(applyTerminalFrameInScene(renderer, new Set(), frame)).toBeNull();
    expect(applyTerminalFrameInScene(renderer, new Set(["another-surface"]), frame)).toBeNull();
    expect(applyCalls).toBe(0);

    const result = applyTerminalFrameInScene(renderer, new Set([frame.surfaceId]), frame);
    expect(result).not.toBeNull();
    await result;
    expect(applyCalls).toBe(1);
  });
});
