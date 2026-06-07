import { describe, expect, test } from "bun:test";

import {
  hasGoogleOAuthProvider,
  isAllowedTypefullyEmail,
  typefullyAccessForUser,
} from "../services/typefully/access";

const baseUser = {
  id: "user-1",
  displayName: "Test User",
  primaryEmail: "writer@manaflow.com",
  primaryEmailVerified: true,
  oauthProviders: [{ id: "google" }],
};

describe("Typefully auth gate", () => {
  test("allows Google users from approved domains", () => {
    expect(typefullyAccessForUser(baseUser)).toEqual({
      ok: true,
      user: {
        id: "user-1",
        email: "writer@manaflow.com",
        displayName: "Test User",
      },
    });
    expect(isAllowedTypefullyEmail("writer@manaflow.ai")).toBe(true);
    expect(isAllowedTypefullyEmail("writer@cmux.com")).toBe(true);
  });

  test("blocks non-approved domains", () => {
    expect(typefullyAccessForUser({
      ...baseUser,
      primaryEmail: "writer@example.com",
    })).toEqual({
      ok: false,
      reason: "domain_not_allowed",
      email: "writer@example.com",
    });
  });

  test("requires Google OAuth", () => {
    expect(hasGoogleOAuthProvider({ oauthProviders: [{ id: "github" }] })).toBe(false);
    expect(typefullyAccessForUser({
      ...baseUser,
      oauthProviders: [{ id: "github" }],
    })).toEqual({
      ok: false,
      reason: "google_required",
      email: "writer@manaflow.com",
    });
  });

  test("requires a verified primary email", () => {
    expect(typefullyAccessForUser({
      ...baseUser,
      primaryEmailVerified: false,
    })).toEqual({
      ok: false,
      reason: "email_unverified",
      email: "writer@manaflow.com",
    });
  });
});
