import { describe, expect, test } from "bun:test";
import { cloudRemoteAuthMode } from "../services/vms/clientGrant";

describe("cloud remote auth mode", () => {
  test("a row without the marker is client-grant unless the caller names compatibility", () => {
    expect(cloudRemoteAuthMode(undefined)).toBe("client-grant");
    expect(cloudRemoteAuthMode(null)).toBe("client-grant");
    expect(cloudRemoteAuthMode({ cmuxRemoteAuth: "bogus" })).toBe("client-grant");
    expect(cloudRemoteAuthMode({}, "trusted-carrier")).toBe("trusted-carrier");
  });

  test("the baked marker wins over any fallback", () => {
    expect(cloudRemoteAuthMode({ cmuxRemoteAuth: "trusted-carrier" })).toBe("trusted-carrier");
    expect(cloudRemoteAuthMode({ cmuxRemoteAuth: "client-grant" }, "trusted-carrier")).toBe("client-grant");
  });
});
