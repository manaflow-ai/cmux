import {
  HEXCLAVE_REQUEST_TIMEOUT_MS,
  hexclaveClientRequest,
  TRANSPORT_FAILURE_CODE,
  type HexclaveResult,
} from "./client";
import type { HexclaveClientConfig } from "./config";
import type { HexclaveSessionTokens } from "./session";

type TokenPairResponse = {
  readonly access_token: string;
  readonly refresh_token: string;
  readonly is_new_user?: boolean;
};

export type HexclaveSignInSuccess = HexclaveSessionTokens & {
  readonly isNewUser: boolean;
};

export type HexclaveOAuthProvider = "google" | "github" | "apple";

export const HEXCLAVE_OAUTH_PROVIDERS: readonly HexclaveOAuthProvider[] = [
  "google",
  "github",
  "apple",
];

export function isHexclaveOAuthProvider(
  value: string,
): value is HexclaveOAuthProvider {
  return (HEXCLAVE_OAUTH_PROVIDERS as readonly string[]).includes(value);
}

export async function signInWithPassword(
  config: HexclaveClientConfig,
  input: { readonly email: string; readonly password: string },
): Promise<HexclaveResult<HexclaveSignInSuccess>> {
  return toSignIn(
    await hexclaveClientRequest<TokenPairResponse>({
      config,
      path: "/auth/password/sign-in",
      body: { email: input.email, password: input.password },
    }),
  );
}

export async function signUpWithPassword(
  config: HexclaveClientConfig,
  input: {
    readonly email: string;
    readonly password: string;
    readonly verificationCallbackURL: string;
  },
): Promise<HexclaveResult<HexclaveSignInSuccess>> {
  return toSignIn(
    await hexclaveClientRequest<TokenPairResponse>({
      config,
      path: "/auth/password/sign-up",
      body: {
        email: input.email,
        password: input.password,
        verification_callback_url: input.verificationCallbackURL,
      },
    }),
  );
}

/** Emails a one-time sign-in code and link. Also creates the user if new. */
export async function sendSignInCode(
  config: HexclaveClientConfig,
  input: { readonly email: string; readonly callbackURL: string },
): Promise<HexclaveResult<{ readonly nonce: string }>> {
  return await hexclaveClientRequest<{ nonce: string }>({
    config,
    path: "/auth/otp/send-sign-in-code",
    body: { email: input.email, callback_url: input.callbackURL },
  });
}

/**
 * Redeems a one-time code. The emailed link carries the whole code; the typed
 * six-digit form carries only its second half, and the nonce carries the rest.
 */
export async function signInWithCode(
  config: HexclaveClientConfig,
  code: string,
): Promise<HexclaveResult<HexclaveSignInSuccess>> {
  return toSignIn(
    await hexclaveClientRequest<TokenPairResponse>({
      config,
      path: "/auth/otp/sign-in",
      body: { code },
    }),
  );
}

export async function sendPasswordResetCode(
  config: HexclaveClientConfig,
  input: { readonly email: string; readonly callbackURL: string },
): Promise<HexclaveResult<void>> {
  const result = await hexclaveClientRequest<unknown>({
    config,
    path: "/auth/password/send-reset-code",
    body: { email: input.email, callback_url: input.callbackURL },
  });
  return result.ok ? { ok: true, value: undefined } : result;
}

export async function verifyPasswordResetCode(
  config: HexclaveClientConfig,
  code: string,
): Promise<HexclaveResult<void>> {
  const result = await hexclaveClientRequest<unknown>({
    config,
    path: "/auth/password/reset/check-code",
    body: { code },
  });
  return result.ok ? { ok: true, value: undefined } : result;
}

export async function resetPassword(
  config: HexclaveClientConfig,
  input: { readonly code: string; readonly password: string },
): Promise<HexclaveResult<void>> {
  const result = await hexclaveClientRequest<unknown>({
    config,
    path: "/auth/password/reset",
    body: { code: input.code, password: input.password },
  });
  return result.ok ? { ok: true, value: undefined } : result;
}

export async function verifyEmailCode(
  config: HexclaveClientConfig,
  code: string,
): Promise<HexclaveResult<void>> {
  const result = await hexclaveClientRequest<unknown>({
    config,
    path: "/contact-channels/verify",
    body: { code },
  });
  return result.ok ? { ok: true, value: undefined } : result;
}

/**
 * Builds the Hexclave outer-OAuth authorize URL. cmux runs the PKCE half of
 * this flow on the server, so the verifier lives in an httpOnly cookie instead
 * of the localStorage entry the browser SDK uses.
 */
export function oauthAuthorizeURL(
  config: HexclaveClientConfig,
  input: {
    readonly provider: HexclaveOAuthProvider;
    readonly redirectURI: string;
    readonly errorRedirectURL: string;
    readonly afterCallbackRedirectURL?: string;
    readonly state: string;
    readonly codeChallenge: string;
  },
): string {
  const url = new URL(
    `${config.apiBaseURL}/api/v1/auth/oauth/authorize/${input.provider}`,
  );
  url.searchParams.set("client_id", config.projectId);
  url.searchParams.set("client_secret", config.publishableClientKey);
  url.searchParams.set("redirect_uri", input.redirectURI);
  url.searchParams.set("scope", "legacy");
  url.searchParams.set("state", input.state);
  url.searchParams.set("grant_type", "authorization_code");
  url.searchParams.set("code_challenge", input.codeChallenge);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("response_type", "code");
  url.searchParams.set("type", "authenticate");
  url.searchParams.set("error_redirect_url", input.errorRedirectURL);
  if (input.afterCallbackRedirectURL) {
    url.searchParams.set(
      "after_callback_redirect_url",
      input.afterCallbackRedirectURL,
    );
  }
  return url.toString();
}

export type HexclaveOAuthExchange = HexclaveSignInSuccess & {
  readonly afterCallbackRedirectURL: string | null;
};

/** Standard authorization-code grant against the Hexclave token endpoint. */
export async function exchangeOAuthCode(
  config: HexclaveClientConfig,
  input: {
    readonly code: string;
    readonly redirectURI: string;
    readonly codeVerifier: string;
  },
): Promise<HexclaveResult<HexclaveOAuthExchange>> {
  let response: Response;
  let text: string;
  try {
    response = await fetch(`${config.apiBaseURL}/api/v1/auth/oauth/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      cache: "no-store",
      signal: AbortSignal.timeout(HEXCLAVE_REQUEST_TIMEOUT_MS),
      body: new URLSearchParams({
        grant_type: "authorization_code",
        client_id: config.projectId,
        client_secret: config.publishableClientKey,
        code: input.code,
        redirect_uri: input.redirectURI,
        code_verifier: input.codeVerifier,
      }),
    });
    text = await response.text();
  } catch (cause) {
    // The visitor is mid-redirect from the provider. A transport failure here
    // must land on the sign-in page, not on an unhandled server error.
    return {
      ok: false,
      error: {
        code: TRANSPORT_FAILURE_CODE,
        message: cause instanceof Error ? cause.message : String(cause),
      },
    };
  }
  // `JSON.parse` happily returns null, a number, or a string. Any of those
  // would throw on the first property read, and this call site is one redirect
  // away from the visitor, so it must fail as a result rather than an
  // exception.
  let parsed: Record<string, unknown>;
  try {
    const body: unknown = JSON.parse(text);
    if (typeof body !== "object" || body === null || Array.isArray(body)) {
      throw new Error("token endpoint returned a non-object body");
    }
    parsed = body as Record<string, unknown>;
  } catch {
    return { ok: false, error: { code: "OAUTH_TOKEN_MALFORMED", message: text } };
  }

  if (!response.ok || typeof parsed.access_token !== "string") {
    const details = parsed.details as { attempt_code?: unknown } | undefined;
    return {
      ok: false,
      error: {
        code: typeof parsed.code === "string" ? parsed.code : "OAUTH_TOKEN_FAILED",
        message: typeof details?.attempt_code === "string"
          ? details.attempt_code
          : text,
      },
    };
  }

  return {
    ok: true,
    value: {
      accessToken: parsed.access_token,
      refreshToken: String(parsed.refresh_token ?? ""),
      isNewUser: parsed.is_new_user === true,
      afterCallbackRedirectURL:
        typeof parsed.after_callback_redirect_url === "string"
          ? parsed.after_callback_redirect_url
          : null,
    },
  };
}

function toSignIn(
  result: HexclaveResult<TokenPairResponse>,
): HexclaveResult<HexclaveSignInSuccess> {
  if (!result.ok) return result;
  return {
    ok: true,
    value: {
      accessToken: result.value.access_token,
      refreshToken: result.value.refresh_token,
      isNewUser: result.value.is_new_user === true,
    },
  };
}

/**
 * The placeholder Hexclave returns instead of a relying-party id, because only
 * the origin serving the page knows which hostname the passkey is scoped to.
 */
const PASSKEY_RP_ID_SENTINEL = "THIS_VALUE_WILL_BE_REPLACED.example.com";

export type PasskeyChallenge = {
  readonly optionsJSON: Record<string, unknown>;
  readonly code: string;
};

/**
 * Asks for a WebAuthn assertion challenge and binds it to this hostname.
 *
 * The browser SDK rewrites the relying-party id from `window.location`, which
 * means a page that was framed or proxied could silently ask for the wrong
 * one. Doing it here ties the challenge to the host that actually served the
 * request.
 */
export async function initiatePasskeyAuthentication(
  config: HexclaveClientConfig,
  hostname: string,
): Promise<HexclaveResult<PasskeyChallenge>> {
  const result = await hexclaveClientRequest<{
    options_json: Record<string, unknown>;
    code: string;
  }>({
    config,
    path: "/auth/passkey/initiate-passkey-authentication",
    body: {},
  });
  if (!result.ok) return result;
  if (result.value.options_json.rpId !== PASSKEY_RP_ID_SENTINEL) {
    return {
      ok: false,
      error: {
        code: "PASSKEY_WEBAUTHN_ERROR",
        message: "Unexpected relying-party id from the auth API",
      },
    };
  }
  return {
    ok: true,
    value: {
      optionsJSON: { ...result.value.options_json, rpId: hostname },
      code: result.value.code,
    },
  };
}

export async function signInWithPasskey(
  config: HexclaveClientConfig,
  input: {
    readonly authenticationResponse: unknown;
    readonly code: string;
  },
): Promise<HexclaveResult<HexclaveSignInSuccess>> {
  return toSignIn(
    await hexclaveClientRequest<TokenPairResponse>({
      config,
      path: "/auth/passkey/sign-in",
      body: {
        authentication_response: input.authenticationResponse,
        code: input.code,
      },
    }),
  );
}
