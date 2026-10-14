import type { CurrentUser } from "@hexclave/next";
import type { SignInFacts } from "../../lib/sign-in-methods";

/**
 * Sign-in facts from the current user. Like Hexclave, OAuth counts every
 * linked provider from the user record (`oauthProviders`), so the OTP and
 * passkey guards need no extra request.
 */
export function signInFacts(
  user: Pick<CurrentUser, "hasPassword" | "otpAuthEnabled" | "passkeyAuthEnabled" | "oauthProviders">,
  oauthSignInCount: number = user.oauthProviders.length,
): SignInFacts {
  return {
    hasPassword: user.hasPassword,
    otpAuthEnabled: user.otpAuthEnabled,
    passkeyAuthEnabled: user.passkeyAuthEnabled,
    oauthSignInCount,
  };
}
