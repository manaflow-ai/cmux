import { describe, expect, test } from "bun:test";

import {
  FREESTYLE_PORT_RULE_DOMAIN_RE,
  freestyleModelPlaneEdgeRuleOptions,
  mintFreestylePortRuleDomain,
  MODEL_PLANE_EDGE_PLACEHOLDER_KEY,
} from "../services/vms/drivers/freestyle";
import { validateTlsRule } from "freestyle";
import { vmModelPlaneEdgeInjectionEnabled } from "../services/vms/config";

// Port previews and model-plane edge injection are built on Freestyle TLS
// rules. The rule shapes are pure builders; validate them with the SDK's own
// validator so a shape the server would refuse fails here, not in production.
describe("freestyle TLS rules", () => {
  test("port preview domains are unguessable style.dev capability URLs", () => {
    const a = mintFreestylePortRuleDomain();
    const b = mintFreestylePortRuleDomain();
    expect(a).not.toBe(b);
    expect(FREESTYLE_PORT_RULE_DOMAIN_RE.test(a)).toBe(true);
    // 96 bits of entropy: the subdomain is the token.
    expect(FREESTYLE_PORT_RULE_DOMAIN_RE.exec(a)![1]).toHaveLength(24);
  });

  test("the ingress port rule passes the SDK's own validation", () => {
    const rule = {
      action: "allow" as const,
      domain: mintFreestylePortRuleDomain(),
      source: { public: true as const },
      destination: { vmId: "vm-123456", port: 3000 },
    };
    expect(() => validateTlsRule(rule)).not.toThrow();
  });

  test("the model-plane edge rule injects both auth headers for the VM only", () => {
    const rule = freestyleModelPlaneEdgeRuleOptions("vm-123456", {
      OPENAI_BASE_URL: "https://cmux.com/v1",
      OPENAI_API_KEY: "crt_secret",
      CMUX_CODEROUTER_URL: "https://cmux.com",
    });
    expect(rule).not.toBeNull();
    expect(rule!.domain).toBe("cmux.com");
    expect(rule!.source).toEqual({ vmId: "vm-123456" });
    expect(rule!.destination).toEqual({ public: true });
    expect(rule!.transform).toEqual([
      {
        headers: {
          authorization: "Bearer crt_secret",
          "x-coderouter-route-token": "crt_secret",
        },
      },
    ]);
    expect(() => validateTlsRule(rule)).not.toThrow();
  });

  test("no edge rule without a base URL or key to move", () => {
    expect(freestyleModelPlaneEdgeRuleOptions("vm-1", {})).toBeNull();
    expect(freestyleModelPlaneEdgeRuleOptions("vm-1", { OPENAI_BASE_URL: "https://cmux.com/v1" })).toBeNull();
    expect(freestyleModelPlaneEdgeRuleOptions("vm-1", { OPENAI_API_KEY: "crt_x" })).toBeNull();
    expect(freestyleModelPlaneEdgeRuleOptions("vm-1", { OPENAI_BASE_URL: "not a url", OPENAI_API_KEY: "crt_x" })).toBeNull();
  });

  test("edge injection is opt-in and the placeholder key is non-empty", () => {
    expect(vmModelPlaneEdgeInjectionEnabled({})).toBe(false);
    expect(vmModelPlaneEdgeInjectionEnabled({ CMUX_VM_MODEL_PLANE_EDGE_INJECTION: "1" })).toBe(true);
    expect(vmModelPlaneEdgeInjectionEnabled({ CMUX_VM_MODEL_PLANE_EDGE_INJECTION: "0" })).toBe(false);
    // Agent configs refuse an empty key; the guest-side placeholder must exist.
    expect(MODEL_PLANE_EDGE_PLACEHOLDER_KEY.length).toBeGreaterThan(0);
  });
});
