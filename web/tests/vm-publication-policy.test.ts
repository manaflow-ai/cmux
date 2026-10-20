import { describe, expect, test } from "bun:test";
import {
  validVmPublicationPolicy,
  vmPublicationAllowsViewer,
  vmPublicationCanManage,
} from "../services/vm-publications/policy";

describe("Cloud VM publication access policy", () => {
  test("personal access admits only the owner", () => {
    const publication = { ownerUserId: "owner", accessMode: "personal" as const, teamId: null };
    expect(vmPublicationAllowsViewer(publication, { userId: "owner", teamIds: [] })).toBe(true);
    expect(vmPublicationAllowsViewer(publication, { userId: "viewer", teamIds: [] })).toBe(false);
    expect(vmPublicationAllowsViewer(publication, null)).toBe(false);
  });

  test("team access follows current membership and public needs no identity", () => {
    const publication = { ownerUserId: "owner", accessMode: "team" as const, teamId: "team-1" };
    expect(vmPublicationAllowsViewer(publication, { userId: "viewer", teamIds: ["team-1"] })).toBe(true);
    expect(vmPublicationAllowsViewer(publication, { userId: "owner", teamIds: [] })).toBe(false);
    expect(vmPublicationAllowsViewer({ ...publication, accessMode: "public", teamId: null }, null)).toBe(true);
  });

  test("rejects a team policy without a team and a personal/public policy with one", () => {
    expect(validVmPublicationPolicy("team", null)).toBeNull();
    expect(validVmPublicationPolicy("team", " team-1 ")).toEqual({ accessMode: "team", teamId: "team-1" });
    expect(validVmPublicationPolicy("personal", "team-1")).toBeNull();
    expect(validVmPublicationPolicy("public", "team-1")).toBeNull();
    expect(validVmPublicationPolicy("public", null)).toEqual({ accessMode: "public", teamId: null });
  });

  test("keeps management with the publication owner", () => {
    expect(vmPublicationCanManage({ ownerUserId: "owner" }, "owner")).toBe(true);
    expect(vmPublicationCanManage({ ownerUserId: "owner" }, "viewer")).toBe(false);
  });
});
