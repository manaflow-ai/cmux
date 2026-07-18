import { describe, expect, test } from "bun:test";
import { normalizeWorkspaceScene } from "../services/share/protocol";

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
});
