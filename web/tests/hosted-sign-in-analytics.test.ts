import { afterEach, describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";

process.env.SKIP_ENV_VALIDATION = "1";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID = "00000000-0000-4000-8000-000000000000";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY = "test-publishable-key";
process.env.STACK_SECRET_SERVER_KEY = "test-secret-key";

const {
  hostedSignInAttempt,
  hostedSignInCapture,
  oauthMethod,
  reportHostedSignInStep,
} = await import("../app/handler/sign-in-analytics");
const { GET: startNativeSignIn } = await import("../app/handler/native-sign-in/route");

const attempt = "0f8fad5b-d9cb-469f-a165-70867728950e";
const afterSignIn = "https://cmux.test/handler/after-sign-in?native_app_return_to=" +
  encodeURIComponent("cmux://auth-callback?cmux_auth_state=state-1");

function signInPage(extra: string): URL {
  const url = `https://cmux.test/handler/native-sign-in?after_auth_return_to=${encodeURIComponent(afterSignIn)}${extra}`;
  const response = startNativeSignIn(new NextRequest(url, { headers: { "sec-fetch-site": "none" } }));
  return new URL(response.headers.get("location")!);
}

describe("the app's opt-in reaches the hosted page", () => {
  test("a valid opt-in and attempt id are forwarded to the sign-in page", () => {
    const page = signInPage(`&cmux_analytics=1&cmux_attempt=${attempt}`);
    expect(page.pathname).toBe("/handler/sign-in");
    expect(page.searchParams.get("cmux_analytics")).toBe("1");
    expect(page.searchParams.get("cmux_attempt")).toBe(attempt);
    expect(hostedSignInAttempt(page.searchParams)).toBe(attempt);
  });

  test("without the app's opt-in, or with a malformed id, nothing is forwarded", () => {
    for (const extra of [
      "",
      `&cmux_attempt=${attempt}`,
      `&cmux_analytics=0&cmux_attempt=${attempt}`,
      "&cmux_analytics=1&cmux_attempt=a%40b.com",
      `&cmux_analytics=1&cmux_attempt=${attempt.toUpperCase()}`,
      `&cmux_analytics=1&cmux_attempt=${attempt}x`,
    ]) {
      const page = signInPage(extra);
      expect(page.searchParams.has("cmux_analytics")).toBe(false);
      expect(page.searchParams.has("cmux_attempt")).toBe(false);
      expect(hostedSignInAttempt(page.searchParams)).toBeNull();
    }
  });

  test("the forwarded values do not change the auth handoff", () => {
    const plain = signInPage("");
    const optedIn = signInPage(`&cmux_analytics=1&cmux_attempt=${attempt}`);
    expect(new URL(optedIn.searchParams.get("after_auth_return_to")!).searchParams.get("native_app_return_to"))
      .toBe(new URL(plain.searchParams.get("after_auth_return_to")!).searchParams.get("native_app_return_to"));
  });
});

describe("hosted sign-in events", () => {
  const realFetch = globalThis.fetch;
  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  function recordFetches() {
    const calls: { url: string; init: RequestInit }[] = [];
    globalThis.fetch = (async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      return new Response(null, { status: 200 });
    }) as typeof fetch;
    return calls;
  }

  test("nothing is sent for a sign-in the app did not opt in", () => {
    const calls = recordFetches();
    reportHostedSignInStep(null, { event: "cmux_sign_in_method_selected", method: "passkey" });
    expect(calls).toHaveLength(0);
  });

  test("an opted-in step posts only the attempt id and bounded values, without a person, GeoIP, cookies or referrer", () => {
    const calls = recordFetches();
    reportHostedSignInStep(attempt, { event: "cmux_sign_in_method_failed", method: oauthMethod("github"), stage: "start" });
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("https://r.cmux.com/e/");
    expect(calls[0].init.credentials).toBe("omit");
    expect(calls[0].init.referrerPolicy).toBe("no-referrer");
    const body = JSON.parse(String(calls[0].init.body));
    expect(body.event).toBe("cmux_sign_in_method_failed");
    expect(body.properties).toEqual({
      distinct_id: attempt,
      attempt_id: attempt,
      source: "hosted_sign_in",
      method: "github",
      stage: "start",
      $process_person_profile: false,
      $geoip_disable: true,
      $lib: "cmux-hosted-sign-in",
    });
  });

  test("every step's properties are allowlisted and bounded", () => {
    const now = new Date(0);
    const steps = [
      { event: "cmux_sign_in_page_shown", page: "sign-in", entry: "choose-account", returningFromProvider: true },
      { event: "cmux_sign_in_method_selected", method: oauthMethod("okta") },
      { event: "cmux_sign_in_method_failed", method: "email_code", stage: "verify" },
    ] as const;
    const keys = steps.map((step) => Object.keys(hostedSignInCapture(attempt, step, now).properties).sort());
    const common = ["$geoip_disable", "$lib", "$process_person_profile", "attempt_id", "distinct_id", "source"];
    expect(keys[0]).toEqual([...common, "entry", "page", "returning_from_provider"].sort());
    expect(keys[1]).toEqual([...common, "method"].sort());
    expect(keys[2]).toEqual([...common, "method", "stage"].sort());
    const shown = hostedSignInCapture(attempt, steps[0], now).properties;
    expect(shown).toMatchObject({ page: "sign_in", entry: "choose_account", returning_from_provider: true });
    expect(hostedSignInCapture(attempt, steps[1], now).properties).toMatchObject({ method: "other_oauth" });
    for (const step of steps) {
      const text = JSON.stringify(hostedSignInCapture(attempt, step, now));
      for (const fragment of ["://cmux", "state-1", "@", "after_auth_return_to", "referrer", "$current_url"]) {
        expect(text.includes(fragment)).toBe(false);
      }
    }
  });
});
