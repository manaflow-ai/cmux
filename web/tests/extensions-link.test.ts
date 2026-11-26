import { describe, expect, mock, test } from "bun:test";
import { createHash } from "node:crypto";
import { pomodoroListing } from "./fixtures/extension-listings";

mock.module("next/cache", () => ({ cacheLife: () => {} }));

const link = await import("../app/extensions/_lib/link");
const registry = await import("../app/extensions/_lib/registry");

const BASE = "https://platform.test";
const SIGN_IN = "/handler/sign-in?after_auth_return_to=%2Fextensions%2Flink";
const SESSION = { accessToken: "stack-access-token", team: "team_0123456789abcdef0123" };

type Call = { url: URL; method: string; authorization: string | null; body: unknown };

function deps(
  answers: Record<string, () => Response>,
  options: { signedIn?: boolean; listings?: Record<string, unknown[]> } = {},
): { deps: import("../app/extensions/_lib/link").LinkDeps; calls: Call[] } {
  const calls: Call[] = [];
  return {
    calls,
    deps: {
      baseUrl: BASE,
      session: async () =>
        options.signedIn === false ? { ok: false, response: link.signInRequired(SIGN_IN) } : { ok: true, session: SESSION },
      fetch: (async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = new URL(String(input));
        const headers = new Headers(init?.headers);
        calls.push({
          url,
          method: init?.method ?? "GET",
          authorization: headers.get("authorization"),
          body: typeof init?.body === "string" ? JSON.parse(init.body) : undefined,
        });
        const answer = answers[`${init?.method ?? "GET"} ${url.pathname}`];
        if (!answer) throw new Error(`unexpected ${url.pathname}`);
        return answer();
      }) as typeof fetch,
      authorListings: async (owner) =>
        (options.listings?.[owner] ?? []).flatMap((item) => registry.parseListing(item) ?? []),
    },
  };
}

const ok = (body: unknown) => () => Response.json(body);
const refusal = (status: number, code: string, message: string) => () =>
  Response.json({ _tag: "Refusal", code, message }, { status });

const post = (body: unknown) =>
  new Request("https://cmux.com/api/extensions/link", { method: "POST", body: JSON.stringify(body) });

describe("link routes: no session", () => {
  test("every route answers 401 with the sign-in URL and never calls the platform", async () => {
    const { deps: d, calls } = deps({}, { signedIn: false });
    const responses = [
      await link.handleStatus(new Request("https://cmux.com/api/extensions/link"), d, SIGN_IN),
      await link.handleRepos(new Request("https://cmux.com/api/extensions/link/repos"), d, SIGN_IN),
      await link.handleLink(post({ repo: "octo-dev/cmux-pomodoro" }), d, SIGN_IN),
      await link.handleUnlink(new Request("https://cmux.com/api/extensions/link?repo=octo-dev/x", { method: "DELETE" }), d, SIGN_IN),
    ];
    for (const response of responses) {
      expect(response.status).toBe(401);
      expect(await response.json()).toMatchObject({ code: "extension.auth_required", signInUrl: SIGN_IN });
    }
    expect(calls).toHaveLength(0);
  });

  test("a platform 401 (expired token) also sends the browser to sign-in", async () => {
    const { deps: d } = deps({ "POST /v1/extensions/link": refusal(401, "extension.auth_required", "sign in") });
    const response = await link.handleLink(post({ repo: "octo-dev/cmux-pomodoro" }), d, SIGN_IN);
    expect(response.status).toBe(401);
    expect((await response.json()).signInUrl).toBe(SIGN_IN);
  });
});

describe("link routes: forwarding", () => {
  test("GitHub status forwards the bearer and the person's team; not connected answers the install URL", async () => {
    const { deps: d, calls } = deps({
      "GET /v1/me/github": ok({ connected: false }),
      "GET /v1/connectors/github/install": ok({ provider: "github", url: "https://github.com/apps/cmux/installations/new?state=s" }),
    });
    const response = await link.handleStatus(new Request("https://cmux.com/api/extensions/link"), d, SIGN_IN);
    expect(await response.json()).toEqual({ connected: false, installUrl: "https://github.com/apps/cmux/installations/new?state=s" });
    expect(response.headers.get("cache-control")).toBe("no-store");
    for (const call of calls) {
      expect(call.authorization).toBe(`Bearer ${SESSION.accessToken}`);
      expect(call.url.searchParams.get("team")).toBe(SESSION.team);
    }
  });

  test("not connected with no install URL says why: an expired sign-in is a 401, a failing registry a 503", async () => {
    const cases: Array<[() => Response, number, string]> = [
      [refusal(401, "auth_required", "sign in"), 401, "extension.auth_required"],
      [refusal(500, "internal", "boom"), 503, "extension.unavailable"],
      [() => new Response("<html>bad gateway</html>", { status: 502 }), 503, "extension.unavailable"],
      [() => new Response("<html>not json</html>", { status: 200 }), 503, "extension.unavailable"],
    ];
    for (const [answer, status, code] of cases) {
      const { deps: d } = deps({
        "GET /v1/me/github": ok({ connected: false }),
        "GET /v1/connectors/github/install": answer,
      });
      const response = await link.handleStatus(new Request("https://cmux.com/api/extensions/link"), d, SIGN_IN);
      expect(response.status).toBe(status);
      expect((await response.json()).code).toBe(code);
    }
  });

  test("a failing install endpoint still answers the connect URL GitHub status gave", async () => {
    const { deps: d } = deps({
      "GET /v1/me/github": ok({ connected: false, connectUrl: "https://cmux.com/connect/github" }),
      "GET /v1/connectors/github/install": refusal(500, "internal", "boom"),
    });
    const response = await link.handleStatus(new Request("https://cmux.com/api/extensions/link"), d, SIGN_IN);
    expect(await response.json()).toEqual({ connected: false, installUrl: "https://cmux.com/connect/github" });
  });

  test("connected GitHub answers the login and never the token", async () => {
    const { deps: d } = deps({ "GET /v1/me/github": ok({ connected: true, login: "octo-dev", source: "github-app" }) });
    const response = await link.handleStatus(new Request("https://cmux.com/api/extensions/link"), d, SIGN_IN);
    const text = await response.text();
    expect(JSON.parse(text)).toEqual({ connected: true, login: "octo-dev" });
    expect(text).not.toContain(SESSION.accessToken);
  });

  test("repos pass search and cursor through, hide private repos and mark the listed ones", async () => {
    const { deps: d, calls } = deps(
      {
        "GET /v1/connectors/github/repos": ok({
          provider: "github",
          repos: [
            { fullName: "octo-dev/cmux-pomodoro", name: "cmux-pomodoro", owner: "octo-dev", private: false },
            { fullName: "octo-dev/new-theme", name: "new-theme", owner: "octo-dev", private: false },
            { fullName: "octo-dev/secret", name: "secret", owner: "octo-dev", private: true },
          ],
          cursor: "page-2",
        }),
      },
      { listings: { "octo-dev": [{ ...pomodoroListing, status: "community" }] } },
    );
    const response = await link.handleRepos(
      new Request("https://cmux.com/api/extensions/link/repos?query=cmux&cursor=page-1"),
      d,
      SIGN_IN,
    );
    expect(calls[0]!.url.searchParams.get("query")).toBe("cmux");
    expect(calls[0]!.url.searchParams.get("cursor")).toBe("page-1");
    expect(await response.json()).toEqual({
      repos: [
        { fullName: "octo-dev/cmux-pomodoro", owner: "octo-dev", name: "cmux-pomodoro", page: "/extensions/octo-dev/cmux-pomodoro", community: true },
        { fullName: "octo-dev/new-theme", owner: "octo-dev", name: "new-theme" },
      ],
      cursor: "page-2",
      hiddenPrivate: 1,
    });
  });

  test("link posts the repo and answers its cmux.com page, or the problem keeping it hidden", async () => {
    const { deps: d, calls } = deps({
      "POST /v1/extensions/link": ok({
        status: "linked",
        ref: "github.com/octo-dev/new-theme",
        kind: "theme",
        page: "https://cmux.com/extensions/octo-dev/new-theme",
        problem: "the marker's id does not start with octo-dev/",
      }),
    });
    const response = await link.handleLink(post({ repo: "octo-dev/new-theme" }), d, SIGN_IN);
    expect(calls[0]!.body).toEqual({ repo: "octo-dev/new-theme" });
    expect(calls[0]!.url.searchParams.get("team")).toBe(SESSION.team);
    expect(await response.json()).toEqual({
      status: "linked",
      ref: "github.com/octo-dev/new-theme",
      kind: "theme",
      page: "/extensions/octo-dev/new-theme",
      problem: "the marker's id does not start with octo-dev/",
    });
  });

  test("a page on another host never becomes a link; cmux.com builds the path itself", async () => {
    const { deps: d } = deps({
      "POST /v1/extensions/link": ok({ status: "linked", ref: "github.com/octo-dev/x", kind: "plugin", page: "https://evil.test/x" }),
    });
    const response = await link.handleLink(post({ repo: "octo-dev/x" }), d, SIGN_IN);
    expect((await response.json()).page).toBe("/extensions/octo-dev/x");
  });

  test("unlink sends the repo as a query and answers unlinked", async () => {
    const { deps: d, calls } = deps({ "DELETE /v1/extensions/link": ok({ status: "unlinked" }) });
    const response = await link.handleUnlink(
      new Request("https://cmux.com/api/extensions/link?repo=octo-dev/new-theme", { method: "DELETE" }),
      d,
      SIGN_IN,
    );
    expect(calls[0]!.method).toBe("DELETE");
    expect(calls[0]!.url.searchParams.get("repo")).toBe("octo-dev/new-theme");
    expect(await response.json()).toEqual({ status: "unlinked" });
  });

  test("a bad repo name is refused before anything is forwarded", async () => {
    const { deps: d, calls } = deps({});
    for (const repo of ["octo-dev", "../etc/passwd", "a/b/c", 42]) {
      expect((await link.handleLink(post({ repo }), d, SIGN_IN)).status).toBe(400);
    }
    expect(calls).toHaveLength(0);
  });
});

describe("link routes: error mapping", () => {
  test("ownership, marker and validation refusals keep their code and status", async () => {
    for (const [status, code] of [
      [403, "extension.not_owner"],
      [403, "extension.private"],
      [404, "extension.no_marker"],
      [422, "extension.no_marker"],
      [429, "extension.rate_limited"],
      [405, "extension.method_not_allowed"],
      [410, "extension.gone"],
      [413, "extension.too_large"],
    ] as const) {
      const { deps: d } = deps({ "POST /v1/extensions/link": refusal(status, code, `${code} message`) });
      const response = await link.handleLink(post({ repo: "octo-dev/x" }), d, SIGN_IN);
      expect(response.status).toBe(status);
      expect(await response.json()).toEqual({ code, message: `${code} message` });
    }
  });

  test("a platform 5xx, a non-JSON answer or a network failure is a 503 unavailable", async () => {
    const answers: Array<() => Response> = [
      refusal(503, "extension.unavailable", "down"),
      () => new Response("<html>bad gateway</html>", { status: 502 }),
      () => {
        throw new TypeError("fetch failed");
      },
    ];
    for (const answer of answers) {
      const { deps: d } = deps({ "POST /v1/extensions/link": answer });
      const response = await link.handleLink(post({ repo: "octo-dev/x" }), d, SIGN_IN);
      expect(response.status).toBe(503);
      expect((await response.json()).code).toBe("extension.unavailable");
    }
  });
});

describe("personal team id", () => {
  test("matches cmux-platform's userIdFor and personalTeamIdFor", () => {
    const hex20 = (value: string) => createHash("sha256").update(value).digest("hex").slice(0, 20);
    const user = `user_${hex20("stack:proj:stack-user")}`;
    expect(link.personalTeamId("proj", "stack-user")).toBe(`team_${hex20(`personal:${user}`)}`);
    expect(link.personalTeamId("proj", "stack-user")).toMatch(/^team_[0-9a-f]{20}$/);
  });

  test("CMUX_PLATFORM_URL overrides the registry worker", () => {
    expect(link.platformBaseUrl({ CMUX_PLATFORM_URL: "https://p.test/" })).toBe("https://p.test");
    expect(link.platformBaseUrl({ CMUX_REGISTRY_URL: "https://r.test" })).toBe("https://r.test");
  });
});
