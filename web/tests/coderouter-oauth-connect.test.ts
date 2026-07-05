import { describe, expect, mock, test } from "bun:test";
import * as Effect from "effect/Effect";
import { makeCoderouterOAuthConnect } from "../services/coderouter/oauthConnect";
import { CoderouterConnectError } from "../services/coderouter/errors";

describe("coderouter OAuth connect", () => {
  test("validates anthropic paste-code state before exchanging tokens", async () => {
    const fetchFn = mock(async () => Response.json({}));
    const connect = makeCoderouterOAuthConnect({ CODEROUTER_KEY_SIGNING_SECRET: "state-secret" }, fetchFn as unknown as typeof fetch);
    const started = await Effect.runPromise(connect.startAnthropic());

    const error = await Effect.runPromise(
      connect.completeAnthropic({
        pastedCode: "auth-code#wrong-state",
        stateCookie: started.cookie,
      }).pipe(Effect.flip),
    );

    expect(error).toBeInstanceOf(CoderouterConnectError);
    expect(error).toMatchObject({ code: "invalid_state" });
    expect(fetchFn).not.toHaveBeenCalled();
  });

  test("exchanges a valid anthropic paste-code and returns a seedable chain", async () => {
    const fetchFn = mock(async (...args: unknown[]) => {
      const init = args[1] as RequestInit | undefined;
      const body = JSON.parse(String(init?.body));
      expect(typeof body.code_verifier).toBe("string");
      return Response.json({
        access_token: "access-token",
        refresh_token: "refresh-token",
        expires_in: 3600,
      });
    });
    const connect = makeCoderouterOAuthConnect({ CODEROUTER_KEY_SIGNING_SECRET: "state-secret" }, fetchFn as unknown as typeof fetch);
    const started = await Effect.runPromise(connect.startAnthropic());
    const chain = await Effect.runPromise(connect.completeAnthropic({
      pastedCode: `auth-code#${started.state}`,
      stateCookie: started.cookie,
    }));

    expect(chain).toMatchObject({
      provider: "anthropic",
      accessToken: "access-token",
      refreshToken: "refresh-token",
    });
    expect(chain.expiresAt).toBeGreaterThan(Date.now());
  });

  test("maps unsupported OpenAI device flow to connect_unsupported", async () => {
    const fetchFn = mock(async () => Response.json({ error: "not_found" }, { status: 404 }));
    const connect = makeCoderouterOAuthConnect({}, fetchFn as unknown as typeof fetch);

    const error = await Effect.runPromise(connect.startOpenAI().pipe(Effect.flip));

    expect(error).toBeInstanceOf(CoderouterConnectError);
    expect(error).toMatchObject({ code: "connect_unsupported" });
  });

  test("parses OpenAI device flow token claims", async () => {
    const idToken = jwt({
      "https://api.openai.com/profile": { email: "owner@example.com" },
      "https://api.openai.com/auth": { chatgpt_account_id: "acct-1" },
    });
    const fetchFn = mock(async () => Response.json({
      access_token: "access-token",
      refresh_token: "refresh-token",
      id_token: idToken,
    }));
    const connect = makeCoderouterOAuthConnect({}, fetchFn as unknown as typeof fetch);

    const result = await Effect.runPromise(connect.pollOpenAI("device-code"));

    expect(result).toEqual({
      status: "complete",
      chain: {
        provider: "openai",
        accessToken: "access-token",
        refreshToken: "refresh-token",
        idToken,
        email: "owner@example.com",
        accountId: "acct-1",
      },
    });
  });
});

function jwt(payload: Record<string, unknown>): string {
  return [
    Buffer.from(JSON.stringify({ alg: "none" })).toString("base64url"),
    Buffer.from(JSON.stringify(payload)).toString("base64url"),
    "signature",
  ].join(".");
}
