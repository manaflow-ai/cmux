import { describe, expect, test } from "bun:test";
import { normalizeTerminalVtFrame, normalizeWorkspaceScene } from "../services/share/protocol";

const baseScene = {
  workspaceId: "workspace",
  workspaceTitle: "Workspace",
  layoutRevision: 1,
  width: 1_000,
  height: 700,
  panes: [{
    id: "pane",
    frame: { x: 0, y: 0, width: 1_000, height: 700 },
    selectedSurfaceId: "browser",
    surfaces: [{ id: "browser", title: "Browser", kind: "browser" }],
  }],
};

describe("share workspace scene", () => {
  test("accepts owned JPEG frames and rejects external image trackers", () => {
    expect(normalizeWorkspaceScene({
      ...baseScene,
      panes: [{
        ...baseScene.panes[0],
        surfaces: [{ ...baseScene.panes[0]!.surfaces[0], imageDataUrl: "data:image/jpeg;base64,AA==" }],
      }],
    })).not.toBeNull();
    expect(normalizeWorkspaceScene({
      ...baseScene,
      panes: [{
        ...baseScene.panes[0],
        surfaces: [{ ...baseScene.panes[0]!.surfaces[0], imageDataUrl: "https://tracker.example/pixel" }],
      }],
    })).toBeNull();
  });

  test("rejects ambiguous or out-of-bounds scene membership", () => {
    expect(normalizeWorkspaceScene({
      ...baseScene,
      panes: [{ ...baseScene.panes[0], selectedSurfaceId: "missing" }],
    })).toBeNull();
    expect(normalizeWorkspaceScene({
      ...baseScene,
      panes: [baseScene.panes[0], { ...baseScene.panes[0] }],
    })).toBeNull();
    expect(normalizeWorkspaceScene({
      ...baseScene,
      panes: [{
        ...baseScene.panes[0],
        frame: { x: 900, y: 0, width: 200, height: 700 },
      }],
    })).toBeNull();
    expect(normalizeWorkspaceScene({
      ...baseScene,
      panes: [{
        ...baseScene.panes[0],
        frame: { x: Number.NaN, y: 0, width: 1_000, height: 700 },
      }],
    })).toBeNull();
  });
});

describe("share terminal VT protocol", () => {
  const frame = {
    surfaceId: "72C552A7-8F75-4DF3-AC47-3750D01D0C18",
    generation: 1,
    stateSeq: 2,
    columns: 120,
    rows: 40,
    kind: "patch",
    dataB64: "G1tI",
  };

  test("accepts the bounded ordered VT transport", () => {
    expect(normalizeTerminalVtFrame(frame)).toEqual(frame);
  });

  test("rejects frames that cannot be replayed safely", () => {
    expect(normalizeTerminalVtFrame({ ...frame, surfaceId: "terminal" })).toBeNull();
    expect(normalizeTerminalVtFrame({ ...frame, generation: 0 })).toBeNull();
    expect(normalizeTerminalVtFrame({ ...frame, stateSeq: Number.MAX_SAFE_INTEGER + 1 })).toBeNull();
    expect(normalizeTerminalVtFrame({ ...frame, columns: 1_001 })).toBeNull();
    expect(normalizeTerminalVtFrame({ ...frame, columns: 501, rows: 400 })).toBeNull();
    expect(normalizeTerminalVtFrame({ ...frame, kind: "delta" })).toBeNull();
    expect(normalizeTerminalVtFrame({ ...frame, dataB64: "***=" })).toBeNull();
  });
});
