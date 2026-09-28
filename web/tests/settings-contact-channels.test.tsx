import { describe, expect, test } from "bun:test";
import {
  emailRowActions,
  hasSignInEmail,
  hasVerifiedSignInEmail,
  isLastSignInEmail,
  sortEmailChannels,
  validateNewEmail,
  type EmailChannelFacts,
} from "../app/[locale]/dashboard/settings/lib/contact-channels";

function channel(overrides: Partial<EmailChannelFacts> & { id: string }): EmailChannelFacts {
  return {
    value: `${overrides.id}@example.com`,
    type: "email",
    isPrimary: false,
    isVerified: true,
    usedForAuth: false,
    ...overrides,
  };
}

const kinds = (actions: ReturnType<typeof emailRowActions>) =>
  actions.map((action) => (action.disabledReason ? `${action.kind}:${action.disabledReason}` : action.kind));

describe("email row actions", () => {
  test("unverified email: send verification, primary disabled, no sign-in toggle, removable", () => {
    expect(kinds(emailRowActions(channel({ id: "a", isVerified: false }), false))).toEqual([
      "sendVerification",
      "setPrimary:verifyFirst",
      "remove",
    ]);
  });

  test("verified secondary email can become primary and a sign-in email", () => {
    expect(kinds(emailRowActions(channel({ id: "a" }), true))).toEqual([
      "setPrimary",
      "useForSignIn",
      "remove",
    ]);
  });

  test("the last sign-in email cannot stop signing in or be removed", () => {
    expect(
      kinds(emailRowActions(channel({ id: "a", isPrimary: true, usedForAuth: true }), true)),
    ).toEqual(["stopUsingForSignIn:lastSignInEmail", "remove:lastSignInEmail"]);
  });

  test("a sign-in email is removable when another sign-in email exists", () => {
    expect(kinds(emailRowActions(channel({ id: "a", usedForAuth: true }), false))).toEqual([
      "setPrimary",
      "stopUsingForSignIn",
      "remove",
    ]);
  });

  test("an unverified sign-in email still offers verification", () => {
    expect(
      kinds(emailRowActions(channel({ id: "a", isVerified: false, usedForAuth: true }), false)),
    ).toEqual(["sendVerification", "setPrimary:verifyFirst", "stopUsingForSignIn", "remove"]);
  });
});

describe("email list facts", () => {
  const list = [
    channel({ id: "unverified", isVerified: false }),
    channel({ id: "verified" }),
    channel({ id: "primary", isPrimary: true, usedForAuth: true }),
    channel({ id: "verified-2" }),
  ];

  test("sorts primary first, then verified, keeping server order otherwise", () => {
    expect(sortEmailChannels(list).map((row) => row.id)).toEqual([
      "primary",
      "verified",
      "verified-2",
      "unverified",
    ]);
  });

  test("counts sign-in emails", () => {
    expect(isLastSignInEmail(list)).toBe(true);
    expect(isLastSignInEmail([...list, channel({ id: "x", usedForAuth: true })])).toBe(false);
    expect(hasSignInEmail(list)).toBe(true);
    expect(hasVerifiedSignInEmail([channel({ id: "u", usedForAuth: true, isVerified: false })])).toBe(false);
    expect(hasVerifiedSignInEmail(list)).toBe(true);
  });
});

describe("validateNewEmail", () => {
  const existing = [{ value: "me@example.com" }];
  test.each<[string, ReturnType<typeof validateNewEmail>]>([
    ["", "required"],
    ["   ", "required"],
    ["not-an-email", "invalid"],
    ["me@localhost", "invalid"],
    ["a..b@example.com", "invalid"],
    ["ME@example.com", "duplicate"],
    [" new@example.com ", null],
  ])("%p -> %p", (value, expected) => {
    expect(validateNewEmail(value, existing)).toBe(expected);
  });
});
