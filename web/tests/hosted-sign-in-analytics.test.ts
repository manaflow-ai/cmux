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
  startHostedSignInPage,
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

  test("a page load reports once, then only its first interaction, with no target or value", () => {
    const calls = recordFetches();
    const page = new EventTarget();
    const shown = { event: "cmux_sign_in_page_shown", page: "sign-in", entry: "form", returningFromProvider: false } as const;
    const pageAttempt = "1b4e28ba-2fa1-41d2-883f-0016d3cca427";

    startHostedSignInPage(null, shown, page);
    page.dispatchEvent(new Event("pointerdown"));
    expect(calls).toHaveLength(0);

    startHostedSignInPage(pageAttempt, shown, page);
    // Strict Mode runs the effect twice; the page load is reported once.
    startHostedSignInPage(pageAttempt, shown, page);
    expect(calls.map((call) => JSON.parse(String(call.init.body)).event)).toEqual(["cmux_sign_in_page_shown"]);

    page.dispatchEvent(new Event("keydown"));
    page.dispatchEvent(new Event("pointerdown"));
    page.dispatchEvent(new Event("keydown"));
    const events = calls.map((call) => JSON.parse(String(call.init.body)));
    expect(events.map((event) => event.event)).toEqual(["cmux_sign_in_page_shown", "cmux_sign_in_page_interacted"]);
    expect(Object.keys(events[1].properties).sort()).toEqual(
      ["$geoip_disable", "$lib", "$process_person_profile", "attempt_id", "distinct_id", "source"],
    );
  });

  test("a page reporter cleaned up before any interaction ignores later presses", () => {
    const calls = recordFetches();
    const page = new EventTarget();
    const shown = { event: "cmux_sign_in_page_shown", page: "sign-in", entry: "form", returningFromProvider: false } as const;
    const cleanup = startHostedSignInPage("6fa459ea-ee8a-4ca4-894e-db77e160355e", shown, page);
    cleanup();
    // The sign-in page is gone; a press on whatever replaced it is not its interaction.
    page.dispatchEvent(new Event("pointerdown"));
    page.dispatchEvent(new Event("keydown"));
    expect(calls.map((call) => JSON.parse(String(call.init.body)).event)).toEqual(["cmux_sign_in_page_shown"]);
  });

  test("effect-style setup, cleanup, setup: one page_shown, listeners again, one interaction", () => {
    const calls = recordFetches();
    const page = new EventTarget();
    const shown = { event: "cmux_sign_in_page_shown", page: "sign-up", entry: "form", returningFromProvider: true } as const;
    const replayAttempt = "16fd2706-8baf-433b-82eb-8c7fada847da";
    const firstCleanup = startHostedSignInPage(replayAttempt, shown, page);
    firstCleanup();
    const cleanup = startHostedSignInPage(replayAttempt, shown, page);
    page.dispatchEvent(new Event("pointerdown"));
    page.dispatchEvent(new Event("pointerdown"));
    // A later mount of the same attempt after the interaction adds nothing.
    startHostedSignInPage(replayAttempt, shown, page)();
    page.dispatchEvent(new Event("keydown"));
    cleanup();
    expect(calls.map((call) => JSON.parse(String(call.init.body)).event)).toEqual([
      "cmux_sign_in_page_shown",
      "cmux_sign_in_page_interacted",
    ]);
  });

  test("every step's properties are allowlisted and bounded", () => {
    const now = new Date(0);
    const steps = [
      { event: "cmux_sign_in_page_shown", page: "sign-in", entry: "choose-account", returningFromProvider: true },
      { event: "cmux_sign_in_method_selected", method: oauthMethod("okta") },
      { event: "cmux_sign_in_method_failed", method: "email_code", stage: "verify" },
      { event: "cmux_sign_in_page_interacted" },
      { event: "cmux_sign_in_account_chosen", choice: "remembered" },
    ] as const;
    const keys = steps.map((step) => Object.keys(hostedSignInCapture(attempt, step, now).properties).sort());
    const common = ["$geoip_disable", "$lib", "$process_person_profile", "attempt_id", "distinct_id", "source"];
    expect(keys[0]).toEqual([...common, "entry", "page", "returning_from_provider"].sort());
    expect(keys[1]).toEqual([...common, "method"].sort());
    expect(keys[2]).toEqual([...common, "method", "stage"].sort());
    expect(keys[3]).toEqual([...common].sort());
    expect(keys[4]).toEqual([...common, "choice"].sort());
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
