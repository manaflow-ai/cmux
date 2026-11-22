// Verification of App Store signed data (JWS) with Apple's official
// library. One SignedDataVerifier checks one (environment, bundle ID) pair,
// so the unverified header payload only selects which verifier to run; every
// value the server acts on comes from the verified result.

import {
  Environment,
  SignedDataVerifier,
  VerificationException,
  type JWSRenewalInfoDecodedPayload,
  type JWSTransactionDecodedPayload,
  type ResponseBodyV2DecodedPayload,
} from "@apple/app-store-server-library";

import {
  appleAppAppleId,
  appleOnlineChecksEnabled,
  isAcceptedAppleBundleId,
  isSignedAppleEnvironment,
  type SignedAppleEnvironment,
} from "./config";
import { appleRootCertificates } from "./rootCertificates";

type Env = Record<string, string | undefined>;

/** A signed payload was rejected: forged, for another app, or malformed. */
export class AppleVerificationError extends Error {
  constructor(
    readonly reason:
      | "malformed"
      | "unknown_bundle"
      | "unsupported_environment"
      | "invalid_signature"
      | "retryable",
    cause?: unknown,
  ) {
    super(`Apple signed data rejected: ${reason}`, cause === undefined ? undefined : { cause });
    this.name = "AppleVerificationError";
  }
}

export type AppleSignedDataVerifier = {
  verifyTransaction(jws: string): Promise<JWSTransactionDecodedPayload>;
  verifyRenewalInfo(
    jws: string,
    scope: { readonly environment: SignedAppleEnvironment; readonly bundleId: string },
  ): Promise<JWSRenewalInfoDecodedPayload>;
  verifyNotification(signedPayload: string): Promise<ResponseBodyV2DecodedPayload>;
};

export type AppleVerifierOptions = {
  readonly rootCertificates?: readonly Buffer[];
  readonly onlineChecks?: boolean;
  readonly env?: Env;
};

/** Decode a compact JWS payload without verifying it. Selection only. */
export function unverifiedJwsPayload(jws: unknown): Record<string, unknown> {
  if (typeof jws !== "string" || jws.length > 64 * 1024) throw new AppleVerificationError("malformed");
  const parts = jws.split(".");
  if (parts.length !== 3) throw new AppleVerificationError("malformed");
  try {
    const decoded: unknown = JSON.parse(Buffer.from(parts[1]!, "base64url").toString("utf8"));
    if (decoded && typeof decoded === "object" && !Array.isArray(decoded)) {
      return decoded as Record<string, unknown>;
    }
  } catch (error) {
    throw new AppleVerificationError("malformed", error);
  }
  throw new AppleVerificationError("malformed");
}

function signedScope(
  payload: { readonly environment?: unknown; readonly bundleId?: unknown },
  env: Env,
): { environment: SignedAppleEnvironment; bundleId: string } {
  // Xcode and LocalTesting payloads are unsigned; the library would skip the
  // signature check for them, so they are refused before reaching it.
  if (!isSignedAppleEnvironment(payload.environment)) {
    throw new AppleVerificationError("unsupported_environment");
  }
  if (!isAcceptedAppleBundleId(payload.bundleId, env)) throw new AppleVerificationError("unknown_bundle");
  return { environment: payload.environment, bundleId: payload.bundleId };
}

function notificationScope(payload: Record<string, unknown>, env: Env) {
  const data = payload.data && typeof payload.data === "object"
    ? payload.data as Record<string, unknown>
    : payload.summary && typeof payload.summary === "object"
      ? payload.summary as Record<string, unknown>
      : null;
  if (!data) throw new AppleVerificationError("malformed");
  return signedScope(data, env);
}

async function withVerificationErrors<T>(operation: () => Promise<T>): Promise<T> {
  try {
    return await operation();
  } catch (error) {
    if (error instanceof AppleVerificationError) throw error;
    if (error instanceof VerificationException) {
      // RETRYABLE_VERIFICATION_FAILURE: OCSP was unreachable.
      throw new AppleVerificationError(error.status === 2 ? "retryable" : "invalid_signature", error);
    }
    throw new AppleVerificationError("invalid_signature", error);
  }
}

export function createAppleSignedDataVerifier(options: AppleVerifierOptions = {}): AppleSignedDataVerifier {
  const env = options.env ?? process.env;
  const roots = [...(options.rootCertificates ?? appleRootCertificates())];
  const onlineChecks = options.onlineChecks ?? appleOnlineChecksEnabled(env);
  const verifiers = new Map<string, SignedDataVerifier>();
  const verifierFor = (scope: { environment: SignedAppleEnvironment; bundleId: string }) => {
    const key = `${scope.environment}:${scope.bundleId}`;
    let verifier = verifiers.get(key);
    if (!verifier) {
      verifier = new SignedDataVerifier(
        roots,
        onlineChecks,
        scope.environment === "Production" ? Environment.PRODUCTION : Environment.SANDBOX,
        scope.bundleId,
        scope.environment === "Production" ? appleAppAppleId(env) : undefined,
      );
      verifiers.set(key, verifier);
    }
    return verifier;
  };
  return {
    verifyTransaction: (jws) => withVerificationErrors(async () => {
      const scope = signedScope(unverifiedJwsPayload(jws), env);
      return await verifierFor(scope).verifyAndDecodeTransaction(jws);
    }),
    verifyRenewalInfo: (jws, scope) => withVerificationErrors(async () => {
      signedScope(scope, env);
      return await verifierFor(scope).verifyAndDecodeRenewalInfo(jws);
    }),
    verifyNotification: (signedPayload) => withVerificationErrors(async () => {
      const scope = notificationScope(unverifiedJwsPayload(signedPayload), env);
      return await verifierFor(scope).verifyAndDecodeNotification(signedPayload);
    }),
  };
}

let defaultVerifier: AppleSignedDataVerifier | null = null;

/** Process-wide verifier, so the library's certificate cache is reused. */
export function appleSignedDataVerifier(): AppleSignedDataVerifier {
  defaultVerifier ??= createAppleSignedDataVerifier();
  return defaultVerifier;
}
