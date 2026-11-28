import { describe, expect, test } from "bun:test";
import {
  PUBLICATION_CALLBACK_PATH,
  PUBLICATION_SESSION_COOKIE,
  hashPublicationToken,
  isPublicationToken,
  normalizePublicationHostname,
  parsePublicationTransactionCookie,
  publicationCookie,
  publicationCookieHeader,
  publicationHostnameFromHeader,
  publicationPkceChallenge,
  publicationSecretMatches,
  publicationTransactionCookieValue,
  randomPublicationToken,
  safePublicationReturnPath,
} from "../services/vm-publications/security";

describe("Cloud VM publication security primitives", () => {
  test("mints URL-safe high-entropy bearer material and hashes it", () => {
    const first = randomPublicationToken();
    const second = randomPublicationToken();
    expect(first).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(first).not.toBe(second);
    expect(hashPublicationToken(first)).toMatch(/^[a-f0-9]{64}$/);
    expect(publicationPkceChallenge(first)).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(isPublicationToken(first)).toBe(true);
    expect(isPublicationToken("short")).toBe(false);
  });

  test("binds an opaque transaction handle to its host-only PKCE verifier", () => {
    const transaction = randomPublicationToken();
    const verifier = randomPublicationToken();
    const encoded = publicationTransactionCookieValue(transaction, verifier);

    expect(parsePublicationTransactionCookie(encoded)).toEqual({
      transaction,
      verifier,
    });
    expect(parsePublicationTransactionCookie(`${transaction}.short`)).toBeNull();
    expect(parsePublicationTransactionCookie(`${transaction}.${verifier}.extra`)).toBeNull();
  });

  test("normalizes exact hostnames while rejecting ports, paths, and wildcards", () => {
    expect(normalizePublicationHostname("Demo.Example.com.")).toBe("demo.example.com");
    expect(publicationHostnameFromHeader("demo.example.com:443")).toBe("demo.example.com");
    expect(normalizePublicationHostname("*.example.com")).toBeNull();
    expect(normalizePublicationHostname("example.com:8443")).toBeNull();
    expect(normalizePublicationHostname("example.com/path")).toBeNull();
    expect(normalizePublicationHostname("-bad.example.com")).toBeNull();
  });

  test("keeps return paths same-origin and prevents callback loops", () => {
    expect(safePublicationReturnPath("/hello?tab=one#ignored")).toBe("/hello?tab=one");
    expect(safePublicationReturnPath("https://evil.test/steal")).toBe("/");
    expect(safePublicationReturnPath("//evil.test/steal")).toBe("/");
    expect(safePublicationReturnPath(PUBLICATION_CALLBACK_PATH)).toBe("/");
  });

  test("extracts exact cookies and emits a host-only secure contract", () => {
    expect(publicationCookie("other=1; __Host-cmux-preview=opaque; next=2", PUBLICATION_SESSION_COOKIE))
      .toBe("opaque");
    expect(publicationCookie("cmux-preview=wrong", PUBLICATION_SESSION_COOKIE)).toBeNull();
    const serialized = publicationCookieHeader(PUBLICATION_SESSION_COOKIE, "opaque", 60);
    expect(serialized).toContain("Path=/");
    expect(serialized).toContain("Secure");
    expect(serialized).toContain("HttpOnly");
    expect(serialized).toContain("SameSite=Lax");
    expect(serialized).not.toContain("Domain=");
  });

  test("fails closed when the service secret is missing or different", () => {
    expect(publicationSecretMatches("shared-secret", "shared-secret")).toBe(true);
    expect(publicationSecretMatches("other-secret", "shared-secret")).toBe(false);
    expect(publicationSecretMatches(null, "shared-secret")).toBe(false);
    expect(publicationSecretMatches("shared-secret", undefined)).toBe(false);
  });
});
