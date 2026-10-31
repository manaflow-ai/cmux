import { describe, expect, test } from "bun:test";
import { startRefusalAction } from "./startRefusal";

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
