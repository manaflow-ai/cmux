import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { isOnlySignInMethod, type SignInFacts } from "../dashboard-app/screens/settings/lib/sign-in-methods";

mock.module("next-intl", () => ({
  useTranslations: () => (key: string) => key,
}));

const { PasskeySection } = await import("../dashboard-app/screens/settings/components/auth/passkey-section");
const { OtpSection } = await import("../dashboard-app/screens/settings/components/auth/otp-section");

const none: SignInFacts = { hasPassword: false, otpAuthEnabled: false, passkeyAuthEnabled: false, oauthSignInCount: 0 };

describe("isOnlySignInMethod", () => {
  test("OTP is the last method only when nothing else can sign in", () => {
    expect(isOnlySignInMethod("otp", { ...none, otpAuthEnabled: true })).toBe(true);
    expect(isOnlySignInMethod("otp", { ...none, otpAuthEnabled: true, hasPassword: true })).toBe(false);
    expect(isOnlySignInMethod("otp", { ...none, otpAuthEnabled: true, passkeyAuthEnabled: true })).toBe(false);
    expect(isOnlySignInMethod("otp", { ...none, otpAuthEnabled: true, oauthSignInCount: 1 })).toBe(false);
    expect(isOnlySignInMethod("otp", none)).toBe(false);
  });

  test("passkey is the last method only when nothing else can sign in", () => {
    expect(isOnlySignInMethod("passkey", { ...none, passkeyAuthEnabled: true })).toBe(true);
    expect(isOnlySignInMethod("passkey", { ...none, passkeyAuthEnabled: true, otpAuthEnabled: true })).toBe(false);
  });

  test("one OAuth provider is last; a second provider or password frees it", () => {
    expect(isOnlySignInMethod("oauth", { ...none, oauthSignInCount: 1 })).toBe(true);
    expect(isOnlySignInMethod("oauth", { ...none, oauthSignInCount: 2 })).toBe(false);
    expect(isOnlySignInMethod("oauth", { ...none, oauthSignInCount: 1, hasPassword: true })).toBe(false);
  });
});

type FakeUser = Parameters<typeof PasskeySection>[0]["user"];

function signInEmails(verified = true) {
  return [{ id: "c1", value: "me@example.com", type: "email" as const, isPrimary: true, isVerified: verified, usedForAuth: true }];
}

function fakeUser(overrides: Record<string, unknown>): FakeUser {
  return {
    hasPassword: false,
    otpAuthEnabled: false,
    passkeyAuthEnabled: false,
    oauthProviders: [],
    update: async () => undefined,
    registerPasskey: async () => ({ status: "ok", data: undefined }),
    ...overrides,
  } as unknown as FakeUser;
}

describe("sign-in method sections", () => {
  test("passkey cannot be disabled when it is the only sign-in method", () => {
    const html = renderToStaticMarkup(<PasskeySection user={fakeUser({ passkeyAuthEnabled: true })} channels={signInEmails()} />);
    expect(html).toContain("onlyMethod");
    expect(html).not.toContain(">delete<");
  });

  test("passkey can be disabled when a password also exists", () => {
    const html = renderToStaticMarkup(
      <PasskeySection user={fakeUser({ passkeyAuthEnabled: true, hasPassword: true })} channels={signInEmails()} />,
    );
    expect(html).toContain(">delete<");
    expect(html).not.toContain("onlyMethod");
  });

  test("passkey registration needs a verified sign-in email", () => {
    expect(renderToStaticMarkup(<PasskeySection user={fakeUser({})} channels={signInEmails(false)} />)).toContain("needsVerifiedEmail");
    expect(renderToStaticMarkup(<PasskeySection user={fakeUser({})} channels={signInEmails()} />)).toContain(">add<");
  });

  test("OTP cannot be disabled when it is the only sign-in method", () => {
    const html = renderToStaticMarkup(<OtpSection user={fakeUser({ otpAuthEnabled: true })} channels={signInEmails()} />);
    expect(html).toContain("onlyMethod");
    const withOAuth = renderToStaticMarkup(
      <OtpSection user={fakeUser({ otpAuthEnabled: true, oauthProviders: [{ id: "github" }] })} channels={signInEmails()} />,
    );
    expect(withOAuth).toContain(">disable<");
  });
});
