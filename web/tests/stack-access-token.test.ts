import { beforeAll, describe, expect, test } from "bun:test";
import {
  SignJWT,
  createLocalJWKSet,
  exportJWK,
  generateKeyPair,
  type JWK,
  type JWTVerifyGetKey,
  type KeyObject,
} from "jose";

import {
  stackIssuer,
  stackJwksURL,
  verifyStackAccessTokenLocally,
} from "../services/auth/stackAccessToken";

const PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895";
const OTHER_PROJECT = "9790718f-0000-4000-8000-000000000000";
const API = "https://api.stack-auth.com";
const NOW = new Date("2026-09-02T12:00:00Z");

let signingKey: KeyObject | CryptoKey;
let otherKey: KeyObject | CryptoKey;
let getKey: JWTVerifyGetKey;

beforeAll(async () => {
  const pair = await generateKeyPair("ES256");
  const other = await generateKeyPair("ES256");
  signingKey = pair.privateKey;
  otherKey = other.privateKey;
  const jwk: JWK = { ...(await exportJWK(pair.publicKey)), kid: "k1", alg: "ES256", use: "sig" };
  getKey = createLocalJWKSet({ keys: [jwk] });
});

function claims(overrides: Record<string, unknown> = {}) {
  return {
    sub: "user-1",
    project_id: PROJECT,
    refresh_token_id: "rt-1",
    role: "authenticated",
    is_anonymous: false,
    ...overrides,
  };
}

async function sign(
  payload: Record<string, unknown>,
  options: {
    key?: KeyObject | CryptoKey;
    kid?: string;
    alg?: string;
    issuer?: string | null;
    audience?: string | null;
    expiresAt?: Date;
  } = {},
): Promise<string> {
  const jwt = new SignJWT(payload)
    .setProtectedHeader({ alg: options.alg ?? "ES256", kid: options.kid ?? "k1" })
    .setIssuedAt(Math.floor(NOW.getTime() / 1_000))
    .setExpirationTime(Math.floor((options.expiresAt ?? new Date(NOW.getTime() + 3_600_000)).getTime() / 1_000));
  if (options.issuer !== null) jwt.setIssuer(options.issuer ?? stackIssuer(API, PROJECT));
  if (options.audience !== null) jwt.setAudience(options.audience ?? PROJECT);
  return jwt.sign(options.key ?? signingKey);
}

const verifier = () => ({ projectId: PROJECT, apiBaseURL: API, getKey, now: () => NOW });

describe("Stack access token local verification", () => {
  test("derives the issuer and JWKS URL from the Stack API origin", () => {
    expect(stackIssuer(`${API}/`, PROJECT)).toBe(`${API}/api/v1/projects/${PROJECT}`);
    expect(stackJwksURL(API, PROJECT).href).toBe(
      `${API}/api/v1/projects/${PROJECT}/.well-known/jwks.json`,
    );
  });

  test("accepts a token signed by a published key for this project", async () => {
    const identity = await verifyStackAccessTokenLocally(await sign(claims()), verifier());
    expect(identity).toEqual({
      userId: "user-1",
      projectId: PROJECT,
      refreshTokenId: "rt-1",
      isAnonymous: false,
      expiresAt: new Date(NOW.getTime() + 3_600_000),
    });
  });

  test("rejects an expired token beyond the clock tolerance", async () => {
    const token = await sign(claims(), { expiresAt: new Date(NOW.getTime() - 120_000) });
    expect(await verifyStackAccessTokenLocally(token, verifier())).toBeNull();
  });

  test("accepts a token that expired within the clock tolerance", async () => {
    const token = await sign(claims(), { expiresAt: new Date(NOW.getTime() - 30_000) });
    expect(await verifyStackAccessTokenLocally(token, verifier())).not.toBeNull();
  });

  test("rejects a token for another project (audience, issuer, or claim)", async () => {
    expect(await verifyStackAccessTokenLocally(
      await sign(claims(), { audience: OTHER_PROJECT }), verifier(),
    )).toBeNull();
    expect(await verifyStackAccessTokenLocally(
      await sign(claims(), { issuer: stackIssuer(API, OTHER_PROJECT) }), verifier(),
    )).toBeNull();
    expect(await verifyStackAccessTokenLocally(
      await sign(claims({ project_id: OTHER_PROJECT })), verifier(),
    )).toBeNull();
    expect(await verifyStackAccessTokenLocally(
      await sign(claims(), { issuer: null }), verifier(),
    )).toBeNull();
    expect(await verifyStackAccessTokenLocally(
      await sign(claims(), { audience: null }), verifier(),
    )).toBeNull();
  });

  test("rejects a signature from a key Stack did not publish", async () => {
    expect(await verifyStackAccessTokenLocally(
      await sign(claims(), { key: otherKey }), verifier(),
    )).toBeNull();
    expect(await verifyStackAccessTokenLocally(
      await sign(claims(), { key: otherKey, kid: "unknown" }), verifier(),
    )).toBeNull();
  });

  test("rejects unsigned or non-ES256 tokens and garbage", async () => {
    const [header, payload] = (await sign(claims())).split(".");
    const noneHeader = Buffer.from(JSON.stringify({ alg: "none" })).toString("base64url");
    expect(await verifyStackAccessTokenLocally(`${noneHeader}.${payload}.`, verifier())).toBeNull();
    expect(await verifyStackAccessTokenLocally(`${header}.${payload}.AAAA`, verifier())).toBeNull();
    expect(await verifyStackAccessTokenLocally("not-a-jwt", verifier())).toBeNull();
    expect(await verifyStackAccessTokenLocally("", verifier())).toBeNull();
  });

  test("rejects a token without a subject", async () => {
    expect(await verifyStackAccessTokenLocally(
      await sign(claims({ sub: undefined })), verifier(),
    )).toBeNull();
  });

  test("treats a key-set failure as not verified so the caller can fall back", async () => {
    const failingGetKey: JWTVerifyGetKey = async () => {
      throw new TypeError("fetch failed");
    };
    expect(await verifyStackAccessTokenLocally(
      await sign(claims()), { ...verifier(), getKey: failingGetKey },
    )).toBeNull();
  });
});
