import { describe, expect, it } from "bun:test";
import { canonicalControlPlaneNamespace } from "../src/controlPlane";

describe("control-plane namespace validation", () => {
  it("accepts only known cmux app lanes", () => {
    expect(canonicalControlPlaneNamespace("com.cmux.app")).toBe("com.cmux.app");
    expect(canonicalControlPlaneNamespace("com.cmux.app.beta")).toBe("com.cmux.app.beta");
    expect(canonicalControlPlaneNamespace("mac:com.cmuxterm.app.nightly")).toBe("mac:com.cmuxterm.app.nightly");
    expect(canonicalControlPlaneNamespace("mac:com.cmuxterm.app.debug.lane-a")).toBe("mac:com.cmuxterm.app.debug.lane-a");
    expect(canonicalControlPlaneNamespace("dev.cmux.ios.lane-a")).toBe("dev.cmux.ios.lane-a");
  });

  it("maps legacy callers to one bounded compatibility scope", () => {
    expect(canonicalControlPlaneNamespace(undefined)).toBe("legacy");
    expect(canonicalControlPlaneNamespace("legacy")).toBe("legacy");
    expect(canonicalControlPlaneNamespace("other-app")).toBeNull();
    expect(canonicalControlPlaneNamespace("namespace:attacker")).toBeNull();
    expect(canonicalControlPlaneNamespace(`com.cmux.app.${"x".repeat(33)}`)).toBeNull();
  });
});
