import { describe, expect, test } from "bun:test";

import { ADMIN_EMAIL_DOMAIN, isAdminEmail, isAdminUser } from "../services/admin/access";

describe("admin access", () => {
  test("admin domain is manaflow.ai", () => {
    expect(ADMIN_EMAIL_DOMAIN).toBe("manaflow.ai");
  });

  test("isAdminEmail accepts only exact manaflow.ai addresses", () => {
    expect(isAdminEmail("lawrence@manaflow.ai")).toBe(true);
    expect(isAdminEmail("  Austin@MANAFLOW.AI ")).toBe(true);
    expect(isAdminEmail("someone@sub.manaflow.ai")).toBe(false);
    expect(isAdminEmail("someone@manaflow.ai.evil.com")).toBe(false);
    expect(isAdminEmail("someone@notmanaflow.ai")).toBe(false);
    expect(isAdminEmail("manaflow.ai")).toBe(false);
    expect(isAdminEmail("@manaflow.ai")).toBe(false);
    expect(isAdminEmail("a@")).toBe(false);
    expect(isAdminEmail("")).toBe(false);
    expect(isAdminEmail(null)).toBe(false);
    expect(isAdminEmail(undefined)).toBe(false);
  });

  test("isAdminUser requires a verified, non-anonymous manaflow.ai user", () => {
    expect(
      isAdminUser({ primaryEmail: "lawrence@manaflow.ai", primaryEmailVerified: true, isAnonymous: false }),
    ).toBe(true);
    expect(
      isAdminUser({ primaryEmail: "lawrence@manaflow.ai", primaryEmailVerified: false, isAnonymous: false }),
    ).toBe(false);
    expect(
      isAdminUser({ primaryEmail: "lawrence@manaflow.ai", primaryEmailVerified: true, isAnonymous: true }),
    ).toBe(false);
    expect(
      isAdminUser({ primaryEmail: "person@example.com", primaryEmailVerified: true, isAnonymous: false }),
    ).toBe(false);
    expect(isAdminUser({ primaryEmail: "lawrence@manaflow.ai" })).toBe(false);
    expect(isAdminUser({ primaryEmail: null, primaryEmailVerified: true })).toBe(false);
    expect(isAdminUser(null)).toBe(false);
    expect(isAdminUser(undefined)).toBe(false);
  });
});
