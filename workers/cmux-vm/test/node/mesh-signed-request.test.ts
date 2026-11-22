/**
 * The install-key signature format (mesh M2, cx-0op.4) against the device
 * agent's golden vectors (workers/cmux-vm/mesh/agent/tests/install.rs, made by
 * an independent RFC 6979 signer): the Worker accepts exactly what the agent
 * signs, and nothing else.
 */
import { Effect } from "effect";
import { describe, expect, it } from "vitest";
import { checkSignature, signedMessage, SIGNATURE_SKEW_MS, type SignedFields } from "../../src/mesh/signed-request.ts";

const WG_KEY = "HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=";
const INSTALL = "BGD+1LolWp0xyWHrdMY1bWjASbiSO2H6bOZpYi5g8p+2eQP+EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk=";
const NONCE = "AAECAwQFBgcICQoLDA0ODw";
const SIGNED_AT = 1_791_331_200_000;
const ENROLL_SIG = "i8TqKGzQLbUWcDdlnMbuVFJEqnlpbxgixFOerp5WpH2vrkDiUl5c0/PVTwwll1iXLfbtnmhc6klXWY7rn5oF8w==";
const ROTATE_SIG = "dsakA1uAobgxdRgVmU2Ysxuf2G3BLf66SS+VWllSzdMlQ2BdhUDfK1GZqtcPsEaT5shkpIUpikxBEpCuMBvIHA==";

const enroll: SignedFields = { purpose: "enroll", target: "mesh_abc", wgPublicKey: WG_KEY, installPublicKey: INSTALL, name: "laptop", signedAt: SIGNED_AT, nonce: NONCE };
const rotate: SignedFields = { purpose: "rotate-key", target: "dev_1", wgPublicKey: WG_KEY, installPublicKey: INSTALL, name: "", signedAt: SIGNED_AT, nonce: NONCE };
const check = (fields: SignedFields, signature: string, now = SIGNED_AT) => Effect.runPromise(checkSignature(fields, signature, now));

describe("signed request format", () => {
  it("builds the agent's message bytes", () => {
    expect(signedMessage(enroll)).toBe(`cmux-mesh-v1\nenroll\nmesh_abc\n${WG_KEY}\n${INSTALL}\nlaptop\n1791331200000\n${NONCE}`);
    expect(signedMessage(rotate).split("\n")).toHaveLength(8);
    expect(signedMessage(rotate).split("\n")[5]).toBe("");
  });

  it("accepts the agent's golden enroll and rotate signatures", async () => {
    const enrolled = await check(enroll, ENROLL_SIG);
    expect(enrolled.ok).toBe(true);
    if (enrolled.ok) {
      expect(enrolled.messageSha256).toMatch(/^[0-9a-f]{64}$/u);
      expect(enrolled.expiresAt.getTime()).toBe(SIGNED_AT + SIGNATURE_SKEW_MS);
    }
    expect((await check(rotate, ROTATE_SIG)).ok).toBe(true);
  });

  it("refuses a changed field, a swapped purpose and a malformed key or signature", async () => {
    for (const fields of [
      { ...enroll, name: "laptop2" },
      { ...enroll, target: "mesh_abd" },
      { ...enroll, nonce: "AAECAwQFBgcICQoLDA0ODx" },
      { ...enroll, purpose: "rotate-key" as const },
      { ...enroll, installPublicKey: "B" + "A".repeat(86) + "=" },
    ]) {
      expect(await check(fields, ENROLL_SIG)).toEqual({ ok: false, reason: "invalid" });
    }
    expect(await check(enroll, ROTATE_SIG)).toEqual({ ok: false, reason: "invalid" });
    expect(await check(enroll, "not base64!")).toEqual({ ok: false, reason: "invalid" });
  });

  it("refuses a signedAt more than 120 s from the clock, either way", async () => {
    expect(await check(enroll, ENROLL_SIG, SIGNED_AT + SIGNATURE_SKEW_MS + 1)).toEqual({ ok: false, reason: "stale" });
    expect(await check(enroll, ENROLL_SIG, SIGNED_AT - SIGNATURE_SKEW_MS - 1)).toEqual({ ok: false, reason: "stale" });
    expect((await check(enroll, ENROLL_SIG, SIGNED_AT + SIGNATURE_SKEW_MS)).ok).toBe(true);
  });
});
