import { describe, expect, test } from "bun:test";
import { startRefusalAction, startRefusalRoute } from "./startRefusal";

describe("startRefusalAction", () => {
  test("a teammate's machine offers the person's own new machine", () => {
    expect(startRefusalAction("agent_session.team_vm_blocked")).toBe("newCloudMachine");
  });
  test("a start with no folder offers Choose folder", () => {
    expect(startRefusalAction("app.folder_needed")).toBe("chooseFolder");
  });
  test("anything else offers Retry only", () => {
    for (const code of [undefined, "", "agent_session.host_unverified", "agent_session.timeout"]) {
      expect(startRefusalAction(code)).toBeUndefined();
    }
  });
});

describe("startRefusalRoute", () => {
  test("Choose Folder on another machine opens that machine's folder menu, never this Mac's panel", () => {
    expect(startRefusalRoute("chooseFolder", true)).toBe("machineFolderMenu");
  });
  test("Choose Folder on this Mac opens the open panel", () => {
    expect(startRefusalRoute("chooseFolder", false)).toBe("folderPanel");
  });
  test("New Cloud Machine goes to the Cloud connect anywhere", () => {
    expect(startRefusalRoute("newCloudMachine", true)).toBe("newCloudMachine");
    expect(startRefusalRoute("newCloudMachine", false)).toBe("newCloudMachine");
  });
});
