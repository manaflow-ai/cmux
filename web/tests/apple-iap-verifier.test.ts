import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

import {
  APPLE_ROOT_CA_SHA256_FINGERPRINTS,
  appleRootCertificates,
} from "../services/billing/apple/rootCertificates";
import {
  AppleVerificationError,
  createAppleSignedDataVerifier,
} from "../services/billing/apple/verifier";
import { createAppleTestSigner } from "./helpers/apple-signing";

const env = { APPLE_IAP_BUNDLE_IDS: "com.cmux.app,dev.cmux.app.beta", APPLE_IAP_APP_APPLE_ID: "6783338052" };
const signer = createAppleTestSigner();
const verifier = createAppleSignedDataVerifier({ rootCertificates: [signer.rootCertificate], onlineChecks: false, env });

function transaction(overrides: Record<string, unknown> = {}) {
  return {
    transactionId: "2000000000000001",
    originalTransactionId: "2000000000000001",
    bundleId: "com.cmux.app",
    productId: "com.cmux.app.pro.monthly",
    type: "Auto-Renewable Subscription",
    environment: "Sandbox",
    purchaseDate: Date.UTC(2026, 9, 1),
    expiresDate: Date.UTC(2026, 10, 1),
    signedDate: Date.UTC(2026, 9, 1),
    ...overrides,
  };
}

async function rejection(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(AppleVerificationError);
    return (error as AppleVerificationError).reason;
  }
  throw new Error("expected verification to fail");
}

describe("Apple root certificates", () => {
  test("bundled DER files and inlined bytes match Apple's published fingerprints", () => {
    const inlined = appleRootCertificates();
    const names = Object.keys(APPLE_ROOT_CA_SHA256_FINGERPRINTS) as (keyof typeof APPLE_ROOT_CA_SHA256_FINGERPRINTS)[];
    names.forEach((name, index) => {
      const file = readFileSync(new URL(`../services/billing/apple/certs/${name}`, import.meta.url));
      const fingerprint = createHash("sha256").update(file).digest("hex").toUpperCase();
      expect(fingerprint).toBe(APPLE_ROOT_CA_SHA256_FINGERPRINTS[name]);
      expect(inlined[index]!.equals(file)).toBe(true);
    });
  });
});

describe("Apple signed data verification", () => {
  test("verifies and decodes a transaction signed by the trusted chain", async () => {
    const decoded = await verifier.verifyTransaction(signer.sign(transaction()));
    expect(decoded.productId).toBe("com.cmux.app.pro.monthly");
    expect(decoded.environment).toBe("Sandbox");
  });

  test("rejects a chain that does not end at a trusted root", async () => {
    const forger = createAppleTestSigner("Forger");
    expect(await rejection(verifier.verifyTransaction(forger.sign(transaction())))).toBe("invalid_signature");
  });

  test("rejects the real Apple roots for a locally signed payload", async () => {
    const production = createAppleSignedDataVerifier({ onlineChecks: false, env });
    expect(await rejection(production.verifyTransaction(signer.sign(transaction())))).toBe("invalid_signature");
  });

  test("rejects a tampered payload", async () => {
    const [header, , signature] = signer.sign(transaction()).split(".");
    const forgedBody = Buffer.from(JSON.stringify(transaction({ productId: "com.cmux.app.max.monthly" }))).toString("base64url");
    expect(await rejection(verifier.verifyTransaction(`${header}.${forgedBody}.${signature}`))).toBe("invalid_signature");
  });

  test("refuses unsigned Xcode and LocalTesting environments before the library skips verification", async () => {
    for (const environment of ["Xcode", "LocalTesting"]) {
      expect(await rejection(verifier.verifyTransaction(signer.sign(transaction({ environment }))))).toBe("unsupported_environment");
    }
  });

  test("refuses another app's bundle ID", async () => {
    const jws = signer.sign(transaction({ bundleId: "com.example.other", productId: "com.example.other.pro.monthly" }));
    expect(await rejection(verifier.verifyTransaction(jws))).toBe("unknown_bundle");
  });

  test("refuses malformed input", async () => {
    expect(await rejection(verifier.verifyTransaction("not-a-jws"))).toBe("malformed");
  });

  test("verifies a V2 notification envelope and checks the app Apple ID in Production", async () => {
    const payload = {
      notificationType: "DID_RENEW",
      notificationUUID: "4f6c9f3e-7d43-4b5a-9a0e-2a7e9c1d0001",
      version: "2.0",
      signedDate: Date.UTC(2026, 9, 2),
      data: { bundleId: "com.cmux.app", environment: "Production", appAppleId: 6783338052, status: 1 },
    };
    const decoded = await verifier.verifyNotification(signer.sign(payload));
    expect(decoded.notificationType).toBe("DID_RENEW");
    const wrongApp = { ...payload, data: { ...payload.data, appAppleId: 1 } };
    expect(await rejection(verifier.verifyNotification(signer.sign(wrongApp)))).toBe("invalid_signature");
  });

  test("verifies renewal info only for the requested scope", async () => {
    const renewal = { originalTransactionId: "1", environment: "Sandbox", autoRenewStatus: 1, signedDate: Date.UTC(2026, 9, 1) };
    const decoded = await verifier.verifyRenewalInfo(signer.sign(renewal), { environment: "Sandbox", bundleId: "com.cmux.app" });
    expect(decoded.autoRenewStatus).toBe(1);
    expect(await rejection(verifier.verifyRenewalInfo(signer.sign(renewal), { environment: "Production", bundleId: "com.cmux.app" })))
      .toBe("invalid_signature");
  });
});
