import { name } from "@gdp-ts/core";
import { Effect, Schema } from "effect";
import { expect, it } from "vitest";
import type { Principal } from "../../src/domain/principal.ts";
import { TenantId } from "../../src/lib/ids.ts";
import { vmImageAllowed, vmImageEvidenceOf } from "../../src/proofs/vm-image.ts";
import { vmImagesLayer } from "../../src/upstream/live-images.ts";

it("keeps image evidence only on the exact frozen proof", async () => {
  const principal: Principal = {
    tenantId: Schema.decodeUnknownSync(TenantId)("team_alpha"),
    actor: { kind: "service", serviceId: "cloud-driver" },
    scopes: new Set(["vm:write"]), resourceAllowlist: null, credentialExpiresAt: null,
  };
  const image = { id: "cloud-standard", revision: "r1" };
  await Effect.runPromise(name(principal, (caller) => Effect.gen(function* () {
    const proof = yield* vmImageAllowed(caller, image);
    image.revision = "r2";
    const evidence = vmImageEvidenceOf(proof);
    expect(evidence.receipt).toEqual({ id: "cloud-standard", revision: "r1", displayName: "Cloud standard" });
    expect(evidence.fingerprint).toMatch(/^[a-f0-9]{64}$/u);
    expect(Object.isFrozen(proof)).toBe(true);
    expect(Object.isFrozen(evidence)).toBe(true);
    expect(Object.isFrozen(evidence.receipt)).toBe(true);
    expect(() => vmImageEvidenceOf({ ...proof })).toThrow("not minted");
  })).pipe(Effect.provide(vmImagesLayer(JSON.stringify([{ ...image, displayName: "Cloud standard", snapshotId: "operator-fixture", services: ["cloud-driver"] }])))));
});
