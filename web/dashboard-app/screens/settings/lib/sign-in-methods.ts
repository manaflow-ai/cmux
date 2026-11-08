/** The sign-in facts used by the "last sign-in method" guards. */
export type SignInFacts = {
  readonly hasPassword: boolean;
  readonly otpAuthEnabled: boolean;
  readonly passkeyAuthEnabled: boolean;
  /** Linked OAuth providers that can sign in. */
  readonly oauthSignInCount: number;
};

export type SignInMethod = "otp" | "passkey" | "oauth";

/**
 * True when turning off `method` would leave the user with no way to sign
 * in. Mirrors Hexclave's `isLastAuth` checks for OTP and passkeys, and
 * applies the same rule to a single OAuth provider.
 */
export function isOnlySignInMethod(method: SignInMethod, facts: SignInFacts): boolean {
  const otherMethods = {
    otp: facts.hasPassword || facts.passkeyAuthEnabled || facts.oauthSignInCount > 0,
    passkey: facts.hasPassword || facts.otpAuthEnabled || facts.oauthSignInCount > 0,
    oauth: facts.hasPassword || facts.otpAuthEnabled || facts.passkeyAuthEnabled || facts.oauthSignInCount > 1,
  }[method];
  const enabled = {
    otp: facts.otpAuthEnabled,
    passkey: facts.passkeyAuthEnabled,
    oauth: facts.oauthSignInCount > 0,
  }[method];
  return enabled && !otherMethods;
}
