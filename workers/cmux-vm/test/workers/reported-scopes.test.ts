/** A client may encounter a newer response scope; it must not become authority. */
import { Either, Schema } from "effect";
import { describe, expect, it } from "vitest";
import { ApiKey, CreatedApiKey, CreateApiKeyRequest } from "../../src/api/api-keys.ts";
import { scopeSetOf } from "../../src/domain/scopes.ts";
import { Forbidden } from "../../src/errors.ts";
import { newApiKeyId } from "../../src/lib/ids.ts";

const FUTURE = "vm:future-fixture";
const keyRecord = () => ({
  id: newApiKeyId(), name: "fixture", scopes: ["vm:read", FUTURE], resourceAllowlist: null,
  createdBy: "user:fixture", createdAt: "2026-10-18T00:00:00Z", expiresAt: null, revokedAt: null,
});

describe("reported scope compatibility", () => {
  it("reads a listed key with a permission introduced by a newer server", () => {
    const decoded = Schema.decodeUnknownEither(ApiKey)(keyRecord());
    expect(Either.isRight(decoded)).toBe(true);
    if (Either.isRight(decoded)) expect(decoded.right.scopes).toContain(FUTURE);
  });

  it("reads a newly created key with a newer permission", () => {
    const decoded = Schema.decodeUnknownEither(CreatedApiKey)({ ...keyRecord(), key: "fixture-key" });
    expect(Either.isRight(decoded)).toBe(true);
    if (Either.isRight(decoded)) expect(decoded.right.scopes).toContain(FUTURE);
  });

  it("reads a permission refusal from a newer server", () => {
    const decoded = Schema.decodeUnknownEither(Forbidden)({ _tag: "Forbidden", message: "Permission required", missingScope: FUTURE });
    expect(Either.isRight(decoded)).toBe(true);
    if (Either.isRight(decoded)) expect(decoded.right.missingScope).toBe(FUTURE);
  });

  it("refuses an unfamiliar permission in key creation requests", () => {
    const decode = Schema.decodeUnknownEither(CreateApiKeyRequest);
    expect(Either.isRight(decode({ name: "fixture", scopes: ["vm:read"] }))).toBe(true);
    expect(Either.isLeft(decode({ name: "fixture", scopes: [FUTURE] }))).toBe(true);
  });

  it("never grants authority from an unfamiliar stored permission", () => {
    const scopes = scopeSetOf(["vm:read", FUTURE]);
    expect([...scopes]).toEqual(["vm:read"]);
  });
});
