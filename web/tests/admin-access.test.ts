import { describe, expect, test } from "bun:test";

import { ADMIN_EMAIL_DOMAINS, isAdminEmail, isAdminUser } from "../services/admin/access";

describe("admin access", () => {
  test("admin domains are exactly cmux.com, manaflow.ai, and manaflow.com", () => {
    expect([...ADMIN_EMAIL_DOMAINS]).toEqual(["cmux.com", "manaflow.ai", "manaflow.com"]);
  });

  test("isAdminEmail accepts addresses on every admin domain, any case", () => {
    expect(isAdminEmail("lawrence@manaflow.ai")).toBe(true);
    expect(isAdminEmail("austin@manaflow.com")).toBe(true);
    expect(isAdminEmail("hello@cmux.com")).toBe(true);
    expect(isAdminEmail("  Austin@MANAFLOW.AI ")).toBe(true);
    expect(isAdminEmail("Some.One+tag@Cmux.Com")).toBe(true);
  });

  test("isAdminEmail rejects other domains, subdomains, and lookalikes", () => {
    for (const email of [
      "someone@example.com",
      "someone@gmail.com",
      "someone@sub.manaflow.ai",
      "someone@sub.cmux.com",
      "someone@manaflow.ai.evil.com",
      "someone@cmux.com.evil.com",
      "someone@notmanaflow.ai",
      "someone@xcmux.com",
      "someone@manaflow.ai.",
      "someone@manaflow.io",
      "someone@manaflow.co",
      "someone@cmux.co",
      "someone@cmux.dev",
      "someone@manaflow.a",
      "someone@manaflow.ai​", // zero-width space
      "someone@manaflow.aі", // Cyrillic i
      "someone@мanaflow.ai", // Cyrillic m
      "someone@xn--manaflow-abc.ai",
      "someone@manaflow.ai evil.com",
      "someone@manaflow.ai,evil.com",
      "someone@manaflow.ai/evil.com",
      "someone@manaflow.ai:evil.com",
      "someone@[manaflow.ai]",
      "someone@manaflow_ai",
    ]) {
      expect(isAdminEmail(email)).toBe(false);
    }
  });

  test("isAdminEmail rejects malformed or ambiguous addresses", () => {
    for (const email of [
      "manaflow.ai",
      "@manaflow.ai",
      "a@",
      "",
      "   ",
      "a@evil.com@manaflow.ai",
      '"a@evil.com"@manaflow.ai',
      "a\\@evil.com@manaflow.ai",
      "a b@manaflow.ai",
      "a\tb@manaflow.ai",
      "a,b@manaflow.ai",
      "a(b)@manaflow.ai",
      "a<b>@manaflow.ai",
      `${"a".repeat(65)}@manaflow.ai`,
      "a\nb@manaflow.ai",
      `${"a".repeat(250)}@manaflow.ai`,
    ]) {
      expect(isAdminEmail(email)).toBe(false);
    }
    expect(isAdminEmail(null)).toBe(false);
    expect(isAdminEmail(undefined)).toBe(false);
  });

  test("isAdminUser requires a verified, explicitly non-anonymous admin email", () => {
    const admin = { primaryEmail: "lawrence@manaflow.ai", primaryEmailVerified: true, isAnonymous: false };
    expect(isAdminUser(admin)).toBe(true);
    expect(isAdminUser({ ...admin, primaryEmail: "hello@cmux.com" })).toBe(true);
    expect(isAdminUser({ ...admin, primaryEmail: "hello@manaflow.com" })).toBe(true);

    expect(isAdminUser({ ...admin, primaryEmailVerified: false })).toBe(false);
    expect(isAdminUser({ ...admin, primaryEmailVerified: undefined })).toBe(false);
    expect(isAdminUser({ ...admin, isAnonymous: true })).toBe(false);
    expect(isAdminUser({ ...admin, isAnonymous: undefined })).toBe(false);
    expect(isAdminUser({ ...admin, primaryEmail: "person@example.com" })).toBe(false);
    expect(isAdminUser({ ...admin, primaryEmail: null })).toBe(false);
    expect(isAdminUser({ ...admin, primaryEmail: undefined })).toBe(false);
    expect(isAdminUser({ primaryEmail: "lawrence@manaflow.ai" })).toBe(false);
    expect(isAdminUser(null)).toBe(false);
    expect(isAdminUser(undefined)).toBe(false);
  });
});
