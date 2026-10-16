import { describe, expect, test } from "bun:test";

import {
  FREESTYLE_PORT_RULE_DOMAIN_RE,
  mintFreestylePortRuleDomain,
} from "../services/vms/drivers/freestyle";
import { validateTlsRule } from "freestyle";

// Port previews are built on Freestyle TLS rules. The rule shapes are pure
// builders; validate them with the SDK's own validator so a shape the server
// would refuse fails here, not in production. (Model-plane edge injection has
// its own inline-rule system and tests; see modelPlaneGateway.)
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
});
