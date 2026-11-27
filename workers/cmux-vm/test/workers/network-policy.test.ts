import { name } from "@gdp-ts/core";
import { Effect, Redacted, Schema } from "effect";
import { describe, expect, it } from "vitest";
import type { Principal } from "../../src/domain/principal.ts";
import { TenantId, UserId } from "../../src/lib/ids.ts";
import { httpsOrigin, parseHttpsProxyOrigins } from "../../src/network-origin.ts";
import { tenantPolicyLayer } from "../../src/policy.ts";
import { vmNetworkAllowed, vmNetworkEvidenceOf } from "../../src/proofs/vm-network.ts";

describe("deployment proxy origins", () => {
  it("normalizes exact origins including explicit ports", () => {
    expect(parseHttpsProxyOrigins('["https://API.example.test:443/", "https://api.example.test", "https://api.example.test:8443"]'))
      .toEqual(["https://api.example.test", "https://api.example.test:8443"]);
  });

  it.each([undefined, "not-json", "{}", '["https://api.example.test", 1]', '["https://api.example.test", "http://api.example.test"]'])(
    "disables proxy destinations for an absent or malformed policy", (value) => {
      expect(parseHttpsProxyOrigins(value)).toEqual([]);
    },
  );

  it.each([
    "http://api.example.test", "https://user@api.example.test", "https://api.example.test/path",
    "https://api.example.test?", "https://api.example.test#", "https://api.example.test\\path",
    "https://api.example.test\n", "https://api.example.test/\n", "https://api.example.test:443/../",
  ])("refuses non-origin URL syntax", (value) => {
    expect(httpsOrigin(value)).toBeNull();
  });
});

it("keeps immutable network evidence only on the minted proof", async () => {
  const principal: Principal = {
    tenantId: Schema.decodeUnknownSync(TenantId)("team_alpha"),
    actor: { kind: "session", userId: Schema.decodeUnknownSync(UserId)("user_alpha") },
    scopes: new Set(["vm:write", "vm:network"]),
    resourceAllowlist: null,
    credentialExpiresAt: null,
  };
  const headers = { authorization: "Bearer original-fixture" };
  const proxy = { hostname: "api.cmux.internal", destination: "https://api.example.test", headers: Redacted.make(headers) };
  const input = { publicEgress: true, httpsProxies: [proxy] };
  await Effect.runPromise(name(principal, (caller) => Effect.gen(function* () {
    const proof = yield* vmNetworkAllowed(caller, input);
    input.publicEgress = false;
    proxy.destination = "https://attacker.test";
    headers.authorization = "Bearer changed-fixture";
    input.httpsProxies.length = 0;
    const evidence = vmNetworkEvidenceOf(proof);
    expect(evidence.config.publicEgress).toBe(true);
    expect(evidence.config.httpsProxies[0]?.destination).toEqual({ host: "api.example.test", port: 443 });
    expect(evidence.config.httpsProxies[0] && Redacted.value(evidence.config.httpsProxies[0].headers)).toEqual({ authorization: "Bearer original-fixture" });
    expect(Object.isFrozen(evidence.config)).toBe(true);
    expect(Object.isFrozen(evidence.config.httpsProxies)).toBe(true);
    expect(() => vmNetworkEvidenceOf({ ...proof })).toThrow("not minted");
  })).pipe(Effect.provide(tenantPolicyLayer({ environment: "local", httpsProxyOrigins: ["https://api.example.test"] }))));
});
