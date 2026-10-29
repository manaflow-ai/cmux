import { afterEach, describe, expect, mock, test } from "bun:test";
import { MutationObserver, QueryClient, QueryClientProvider, type UseMutationOptions } from "@tanstack/react-query";
import { renderToStaticMarkup as renderMarkup } from "react-dom/server";
import type React from "react";
import enMessages from "../messages/en.json";
import { coderouterApiKeysQueryKey, coderouterOverviewQuery } from "../dashboard-app/queries/coderouter";
import {
  accountSharingMutation,
  accountWriteErrorKey,
  addApiKeyAccountMutation,
  addClaudeUpstreamMutation,
  apiKeyCreateErrorKey,
  claudeAccountMutation,
  createApiKeyMutation,
  removeNativeAccountMutation,
  removeSharedAccountMutation,
  revokeApiKeyMutation,
  transferErrorKey,
  transferErrorKeyFor,
  transferNativeAccountMutation,
} from "../dashboard-app/queries/coderouter-mutations";

/** Accounts mutate through TanStack Query, so every render needs a client. */
function renderToStaticMarkup(element: React.ReactElement, queryClient = new QueryClient()) {
  return renderMarkup(<QueryClientProvider client={queryClient}>{element}</QueryClientProvider>);
}

mock.module("next-intl", () => ({
  useTranslations: (namespace: string) => translator(namespace),
  useFormatter: () => ({
    dateTime: (date: Date) => date.toISOString().slice(0, 10),
    relativeTime: () => "2 hours ago",
  }),
  useNow: () => new Date("2026-09-07T12:00:00.000Z"),
}));

mock.module("@base-ui-components/react/dialog", () => ({
  Dialog: {
    Root: ({ children, open }: { children: React.ReactNode; open: boolean }) =>
      open ? <div>{children}</div> : null,
    Portal: ({ children }: { children: React.ReactNode }) => <>{children}</>,
    Backdrop: () => null,
    Viewport: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
    Popup: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
    Title: ({ children }: { children: React.ReactNode }) => <h2>{children}</h2>,
    Description: ({ children }: { children: React.ReactNode }) => <p>{children}</p>,
    Close: ({ children }: { children: React.ReactNode }) => <button>{children}</button>,
  },
}));

const { CoderouterAccountsSection } = await import(
  "../dashboard-app/screens/coderouter/coderouter-accounts"
);

const claudeAccount = {
  id: "claude-1",
  kind: "anthropic_oauth" as const,
  label: "work",
  identifier: "sk-ant-oat01-…a1b2",
  region: null,
  modelIds: {},
  state: "active" as const,
  cooldownUntil: null,
  lastFailureCode: null,
  lastUsedAt: "2026-09-07T10:00:00.000Z",
  createdAt: "2026-09-01T00:00:00.000Z",
  updatedAt: "2026-09-01T00:00:00.000Z",
};

const codexAccount = {
  id: "codex-1",
  kind: "codex",
  label: "shared codex",
  createdAt: "2026-08-20T00:00:00.000Z",
  health: { ok: true },
};

const nativeCodexAccount = {
  id: "native-1",
  provider: "codex" as const,
  providerAccountId: "acct_9f3",
  label: "user@example.com",
  state: "active" as const,
  credentialExpiresAt: "2026-09-08T00:00:00.000Z",
  lastFailureCode: null,
  cooldownUntil: null,
  activeSessions: 3,
};

const otherTeams = [{ id: "team-2", name: "Team Two" }];

function renderTransferCase(input: {
  readonly canManage?: boolean;
  readonly transferTeams?: readonly { id: string; name: string }[];
  readonly claudeAccounts?: readonly (typeof claudeAccount)[];
  readonly nativeAccounts?: readonly (typeof nativeCodexAccount)[];
}) {
  return renderToStaticMarkup(
    <CoderouterAccountsSection
      teamId="team-1"
      teamName="Team One"
      canManage={input.canManage ?? true}
      canManageApiKeys={false}
      transferTeams={input.transferTeams}
      claude={{ kind: "ok", accounts: input.claudeAccounts ?? [] }}
      native={{ kind: "ok", accounts: input.nativeAccounts ?? [nativeCodexAccount] }}
      shared={{ kind: "ok", accounts: [] }}
    />,
  );
}


const KEY_ID = "0f4b1c2e-1111-4222-8333-444455556666";

let routeReply: (request: Request) => Promise<Response> = async () => new Response(null, { status: 204 });
// Bun's mock.module also patches namespaces imported earlier, so keep the
// real function in a constant before installing the mock.
const realCallRoute = (await import("../orpc/server/dashboard/route-call")).callRoute;
mock.module("../orpc/server/dashboard/route-call", () => ({
  callRoute: (context: Parameters<typeof realCallRoute>[0], _handler: unknown, call: Parameters<typeof realCallRoute>[2]) =>
    realCallRoute(context, (request: Request) => routeReply(request), call),
}));
const { RPCHandler } = await import("@orpc/server/fetch");
const { coderouterRouter } = await import("../orpc/server/dashboard/coderouter");
const coderouterRpc = new RPCHandler({ coderouter: coderouterRouter });

describe("coderouter account transfer", () => {
  test("offers Transfer on a manageable native account when another team exists", () => {
    const html = renderTransferCase({ transferTeams: otherTeams });
    expect(html.match(/>Transfer</g)).toHaveLength(1);
    // The dialog stays closed until the viewer asks for it.
    expect(html).not.toContain("Transfer account");
  });

  test("hides Transfer when the viewer belongs to no other team", () => {
    expect(renderTransferCase({ transferTeams: [] })).not.toContain(">Transfer<");
    expect(renderTransferCase({})).not.toContain(">Transfer<");
  });

  test("hides Transfer for Claude accounts", () => {
    const html = renderTransferCase({
      transferTeams: otherTeams,
      claudeAccounts: [claudeAccount],
      nativeAccounts: [],
    });
    expect(html).toContain("Claude Code OAuth");
    expect(html).toContain(">Remove<");
    expect(html).not.toContain(">Transfer<");
  });

  test("hides Transfer when the viewer cannot manage accounts", () => {
    const html = renderTransferCase({ canManage: false, transferTeams: otherTeams });
    expect(html).toContain("user@example.com");
    expect(html).not.toContain(">Transfer<");
  });

  test("posts the chosen destination team from the selected source team", async () => {
    const calls = stubRoutes(() => Response.json({ accountId: "native-1" }));
    const queryClient = seededClient();

    await runMutation(transferNativeAccountMutation(queryClient, "team-1"), {
      accountId: "native-1",
      destinationTeamId: "team-2",
    });

    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("/api/coderouter/accounts/native-1/transfer");
    expect(calls[0].method).toBe("POST");
    expect(calls[0].headers.get("x-cmux-team-id")).toBe("team-1");
    expect(calls[0].body).toEqual({ destinationTeamId: "team-2" });
    // The moved account leaves this team's list on the refetch.
    expect(queryClient.getQueryState(coderouterOverviewQuery(undefined).queryKey)?.isInvalidated).toBe(true);
  });

  test("maps the failing status and error code to the dialog's explanation", async () => {
    const failure = async (reply: () => Response) => {
      stubRoutes(reply);
      const queryClient = seededClient();
      const error = await runMutation(
        transferNativeAccountMutation(queryClient, "team-1"),
        { accountId: "native-1", destinationTeamId: "team-2" },
      ).then(() => null, (caught: unknown) => caught);
      // A refused transfer changes nothing, so nothing refetches.
      expect(queryClient.getQueryState(coderouterOverviewQuery(undefined).queryKey)?.isInvalidated).toBe(false);
      return transferErrorKeyFor(error);
    };
    expect(await failure(() => new Response("{}", { status: 409 }))).toBe("transferConflictError");
    expect(await failure(() => Response.json({ error: "forbidden" }, { status: 403 }))).toBe("teamAccessError");
    expect(await failure(() => Response.json({ error: "destination_forbidden" }, { status: 403 })))
      .toBe("transferForbiddenError");
    expect(await failure(() => new Response("<html>", { status: 502 }))).toBe("transferError");
    expect(await failure(() => { throw new TypeError("offline"); })).toBe("transferError");
  });

  test("blames the source team when the viewer lost access to it, and the destination otherwise", () => {
    // The route answers 403 "forbidden" when the viewer can no longer manage
    // the source team, and 403 "destination_forbidden" for the destination.
    expect(transferErrorKey(403, "forbidden")).toBe("teamAccessError");
    expect(transferErrorKey(403, "destination_forbidden")).toBe("transferForbiddenError");
    expect(transferErrorKey(403, null)).toBe("transferForbiddenError");
    expect(transferErrorKey(409, "conflict")).toBe("transferConflictError");
    expect(transferErrorKey(500, null)).toBe("transferError");
    expect(transferErrorKey(null, null)).toBe("transferError");
    expect(enMessages.dashboard.coderouterAccounts.teamAccessError).toBe("You do not have access to this team.");
  });
});

describe("coderouter accounts section", () => {
  test("lists Claude upstream and shared Codex accounts in one table", () => {
    const html = renderToStaticMarkup(
      <CoderouterAccountsSection
        teamId="team-1"
        canManage
        canManageApiKeys
        claude={{ kind: "ok", accounts: [claudeAccount] }}
        native={{ kind: "ok", accounts: [nativeCodexAccount] }}
        shared={{ kind: "ok", accounts: [codexAccount] }}
      />,
    );

    expect(html).toContain("3 accounts");
    expect(html).toContain("user@example.com");
    expect(html).toContain("3 active sessions");
    expect(html.match(/<ul[^>]*>/g)).toHaveLength(1);
    expect(html).toContain("Claude Code OAuth");
    expect(html).toContain("sk-ant-oat01-…a1b2");
    expect(html).toContain("Codex");
    expect(html).toContain("shared codex");
    expect(html).toContain("Last used 2 hours ago");
    expect(html).toContain("Added 2026-08-20");
    // Provider rows are text only.
    expect(html).not.toContain("<svg");
  });

  test("offers every account kind in one add panel, OAuth token included", () => {
    const html = renderToStaticMarkup(
      <CoderouterAccountsSection
        teamId="team-1"
        canManage
        canManageApiKeys
        claude={{ kind: "ok", accounts: [] }}
        native={{ kind: "ok", accounts: [] }}
        shared={{ kind: "ok", accounts: [] }}
      />,
    );

    const tabs = [...html.matchAll(/role="tab"[^>]*>([^<]+)</g)].map((match) => match[1]);
    expect(html).toContain('role="tablist"');
    expect(html).toContain('role="tabpanel"');
    // Base UI marks the current tab with data-active; the selected styles key off it.
    const activeTab = html.match(/<button[^>]*\bdata-active=""[^>]*>([^<]+)</)?.[1];
    expect(activeTab).toBe("Anthropic API key");
    expect(html).toMatch(/data-\[active\]:border-foreground/);
    expect(tabs).toEqual([
      "Anthropic API key",
      "Claude Code OAuth",
      "Amazon Bedrock",
      "OpenAI API key",
      "OpenRouter API key",
      "Codex",
      "OpenCode",
    ]);
    expect(html).toContain("No accounts yet");
    expect(html).toContain('name="apiKey"');
    expect(html).toContain("API keys");
    expect(html).toContain("Create API key");
    expect(html).toContain('name="apiKeyLabel"');
  });

  test("keeps account controls when only API-key management is denied", () => {
    const html = renderToStaticMarkup(
      <CoderouterAccountsSection
        teamId="team-1"
        canManage
        canManageApiKeys={false}
        claude={{ kind: "ok", accounts: [claudeAccount] }}
        native={{ kind: "ok", accounts: [nativeCodexAccount] }}
        shared={{ kind: "ok", accounts: [codexAccount] }}
      />,
    );

    // Every team member manages provider accounts; API keys keep their own gate.
    expect(html).toContain('role="tablist"');
    expect(html).toContain('name="apiKey"');
    expect(html).toContain(">Remove<");
    expect(html).toContain("acct_9f3");
    expect(html).not.toContain('name="apiKeyLabel"');
    expect(html).not.toContain("Create API key");
  });

  test("hides management controls when the viewer cannot manage accounts or API keys", () => {
    const html = renderToStaticMarkup(
      <CoderouterAccountsSection
        teamId="team-1"
        canManage={false}
        canManageApiKeys={false}
        claude={{ kind: "ok", accounts: [claudeAccount] }}
        native={{ kind: "ok", accounts: [nativeCodexAccount] }}
        shared={{ kind: "ok", accounts: [codexAccount] }}
      />,
    );

    expect(html).not.toContain('role="tablist"');
    expect(html).not.toContain(">Remove<");
    expect(html).not.toContain(">Disable<");
    // Provider account identifiers are for account managers only.
    expect(html).not.toContain("acct_9f3");
    expect(html).not.toContain("sk-ant-oat01-…a1b2");
    expect(html).not.toContain('name="apiKeyLabel"');
    expect(html).toContain("Claude Code OAuth");
  });

  test("hides the deployment notice from viewers who cannot manage accounts", () => {
    const render = (canManage: boolean) => renderToStaticMarkup(
      <CoderouterAccountsSection
        teamId="team-1"
        canManage={canManage}
        canManageApiKeys={canManage}
        claude={{ kind: "ok", accounts: [claudeAccount] }}
        native={{ kind: "ok", accounts: [nativeCodexAccount] }}
        shared={{ kind: "notConfigured" }}
      />,
    );
    expect(render(true)).toContain("not listed here");
    expect(render(false)).not.toContain("not listed here");
  });

  test("an unreachable shared-account service explains itself and never claims the team has no accounts", () => {
    const html = renderToStaticMarkup(
      <CoderouterAccountsSection
        teamId="team-1"
        canManage
        canManageApiKeys
        claude={{ kind: "ok", accounts: [] }}
        native={{ kind: "ok", accounts: [] }}
        shared={{ kind: "unavailable" }}
      />,
    );
    expect(html).toContain("Shared accounts are unavailable");
    expect(html).not.toContain("No accounts yet");
    expect(html).not.toContain("Some accounts could not load");
  });

  test("keeps the loaded provider visible when the other one fails", () => {
    const html = renderToStaticMarkup(
      <CoderouterAccountsSection
        teamId="team-1"
        canManage
        canManageApiKeys
        claude={{ kind: "ok", accounts: [claudeAccount] }}
        native={{ kind: "ok", accounts: [] }}
        shared={{ kind: "error" }}
      />,
    );

    expect(html).toContain("Some accounts could not load");
    expect(html).toContain("Claude Code OAuth");
    expect(html).not.toContain("No accounts yet");
  });

  test("explains a pending shared-account migration without hiding Claude accounts", () => {
    const html = renderToStaticMarkup(
      <CoderouterAccountsSection
        teamId="team-1"
        canManage
        canManageApiKeys
        claude={{ kind: "ok", accounts: [claudeAccount] }}
        native={{ kind: "ok", accounts: [] }}
        shared={{ kind: "migrationPending" }}
      />,
    );

    expect(html).toContain("Shared accounts temporarily unavailable");
    expect(html).toContain("Claude Code OAuth");
  });

  test("shows a table skeleton until the team's API keys arrive, then lists them", () => {
    const render = (queryClient: QueryClient) => renderToStaticMarkup(
      <CoderouterAccountsSection
        teamId="team-1"
        canManage
        canManageApiKeys
        claude={{ kind: "ok", accounts: [] }}
        native={{ kind: "ok", accounts: [] }}
        shared={{ kind: "ok", accounts: [] }}
      />,
      queryClient,
    );
    const loading = render(new QueryClient());
    expect(loading).toContain('data-testid="dashboard-section-skeleton"');
    expect(loading).toContain('data-variant="table"');

    const seeded = new QueryClient();
    seeded.setQueryData(coderouterApiKeysQueryKey("team-1"), { keys: [{
      id: "key-1",
      keyPrefix: "cr_live_ab12",
      label: "ci",
      createdAt: "2026-09-01T00:00:00.000Z",
      lastUsedAt: null,
      revokedAt: null,
      usage: null,
    }] });
    // Another team's cached keys never render for this team.
    seeded.setQueryData(coderouterApiKeysQueryKey("team-2"), { keys: [{
      id: "key-2",
      keyPrefix: "cr_live_zz99",
      label: "other",
      createdAt: "2026-09-01T00:00:00.000Z",
      lastUsedAt: null,
      revokedAt: null,
      usage: null,
    }] });
    const html = render(seeded);
    expect(html).not.toContain("Loading API keys");
    expect(html).toContain("cr_live_ab12");
    expect(html).toContain("1 key");
    expect(html).not.toContain("cr_live_zz99");
  });
});

describe("coderouter account mutations", () => {
  const overviewKey = coderouterOverviewQuery(undefined).queryKey;

  test("adds an API-key account with the team header and omits an empty label", async () => {
    const calls = stubRoutes(() => Response.json({ id: "native-2" }, { status: 201 }));
    const queryClient = seededClient();
    await runMutation(addApiKeyAccountMutation(queryClient, "team-1"), {
      provider: "openai-apikey",
      apiKey: "sk-proj-1",
      label: "",
    });
    expect(calls[0].url).toBe("/api/coderouter/accounts");
    expect(calls[0].method).toBe("POST");
    expect(calls[0].headers.get("x-cmux-team-id")).toBe("team-1");
    expect(calls[0].headers.get("content-type")).toBe("application/json");
    expect(calls[0].body).toEqual({ provider: "openai-apikey", apiKey: "sk-proj-1" });
    expect(queryClient.getQueryState(overviewKey)?.isInvalidated).toBe(true);
  });

  test("adds a Claude upstream account scoped by the teamId query", async () => {
    const calls = stubRoutes(() => Response.json({ account: {} }, { status: 201 }));
    await runMutation(addClaudeUpstreamMutation(seededClient(), "team 1"), {
      kind: "anthropic_api_key",
      apiKey: "sk-ant-api03-x",
    });
    expect(calls[0].url).toBe("/api/coderouter/claude-upstream?teamId=team+1");
    expect(calls[0].body).toEqual({ kind: "anthropic_api_key", apiKey: "sk-ant-api03-x" });
  });

  test("toggles and removes a Claude account; a missing row counts as removed only on delete", async () => {
    let status = 200;
    const calls = stubRoutes(() => Response.json({ error: "not_found" }, { status }));
    const queryClient = seededClient();
    const options = claudeAccountMutation(queryClient, "team-1");

    await runMutation(options, { accountId: "claude-1", action: "setState", state: "disabled" });
    expect(calls[0].url).toBe("/api/coderouter/claude-upstream/claude-1?teamId=team-1");
    expect(calls[0].method).toBe("PATCH");
    expect(calls[0].body).toEqual({ state: "disabled" });

    status = 404;
    await runMutation(options, { accountId: "claude-1", action: "remove" });
    expect(calls[1].method).toBe("DELETE");
    const toggleError = await runMutation(options, { accountId: "claude-1", action: "setState", state: "active" })
      .then(() => null, (caught: unknown) => caught);
    expect(accountWriteErrorKey(toggleError, "updateError")).toBe("updateError");
  });

  test("removes a native account; 404 is success, 403 and 400 keep their copy", async () => {
    let status = 404;
    const calls = stubRoutes(() => Response.json({ error: "x" }, { status }));
    const queryClient = seededClient();
    const options = removeNativeAccountMutation(queryClient, "team-1");
    await runMutation(options, "native-1");
    expect(calls[0].url).toBe("/api/coderouter/accounts/native-1");
    expect(calls[0].method).toBe("DELETE");
    expect(calls[0].headers.get("x-cmux-team-id")).toBe("team-1");
    expect(queryClient.getQueryState(overviewKey)?.isInvalidated).toBe(true);

    const failure = async (next: number) => {
      status = next;
      return accountWriteErrorKey(await runMutation(options, "native-1").then(() => null, (caught: unknown) => caught), "removeError");
    };
    expect(await failure(403)).toBe("teamAccessError");
    expect(await failure(400)).toBe("validationError");
    expect(await failure(500)).toBe("removeError");
  });

  test("removes a shared account; the subrouter's 404 and 503 are failures", async () => {
    let status = 404;
    const calls = stubRoutes(() => new Response(null, { status }));
    const queryClient = seededClient();
    const options = removeSharedAccountMutation(queryClient, "team-1");
    const error = await runMutation(options, "codex-1").then(() => null, (caught: unknown) => caught);
    expect(calls[0].url).toBe("/api/subrouter/accounts/codex-1?teamId=team-1");
    expect(accountWriteErrorKey(error, "removeError", "notConfiguredTitle")).toBe("removeError");
    expect(queryClient.getQueryState(overviewKey)?.isInvalidated).toBe(false);

    status = 503;
    const unavailable = await runMutation(options, "codex-1").then(() => null, (caught: unknown) => caught);
    expect(accountWriteErrorKey(unavailable, "removeError", "notConfiguredTitle")).toBe("notConfiguredTitle");

    status = 204;
    await runMutation(options, "codex-1");
    expect(queryClient.getQueryState(overviewKey)?.isInvalidated).toBe(true);
  });

  test("flips account sharing to the requested visibility", async () => {
    const calls = stubRoutes(() => Response.json({ ok: true }));
    await runMutation(accountSharingMutation(seededClient(), "team-1"), {
      accountId: "native-1",
      family: "native",
      visibility: "team",
    });
    expect(calls[0].url).toBe("/api/coderouter/accounts/native-1/sharing");
    expect(calls[0].method).toBe("PATCH");
    expect(calls[0].headers.get("x-cmux-team-id")).toBe("team-1");
    expect(calls[0].body).toEqual({ family: "native", visibility: "team" });
  });

  test("creates an API key and refreshes only that team's key list", async () => {
    const issued = {
      teamId: "team-1",
      id: "key-9",
      key: "cr_live_secret",
      keyPrefix: "cr_live_se",
      label: "ci",
      createdAt: "2026-09-01T00:00:00.000Z",
    };
    const calls = stubRoutes(() => Response.json(issued, { status: 201 }));
    const queryClient = seededClient();
    queryClient.setQueryData(coderouterApiKeysQueryKey("team-1"), { keys: [] });
    const created = await runMutation(createApiKeyMutation(queryClient, "team-1"), "ci");
    expect(created).toMatchObject({ id: "key-9", key: "cr_live_secret" });
    expect(calls[0].url).toBe("/api/coderouter/api-keys");
    expect(calls[0].headers.get("x-cmux-team-id")).toBe("team-1");
    expect(calls[0].body).toEqual({ label: "ci" });
    expect(queryClient.getQueryState(coderouterApiKeysQueryKey("team-1"))?.isInvalidated).toBe(true);
    expect(queryClient.getQueryState(overviewKey)?.isInvalidated).toBe(false);
  });

  test("explains a refused or malformed API key creation", async () => {
    const failure = async (reply: () => Response) => {
      stubRoutes(reply);
      return apiKeyCreateErrorKey(
        await runMutation(createApiKeyMutation(seededClient(), "team-1"), "ci").then(() => null, (caught: unknown) => caught),
      );
    };
    expect(await failure(() => Response.json({ error: "forbidden" }, { status: 403 }))).toBe("teamAccessError");
    expect(await failure(() => Response.json({ error: "api_key_unavailable" }, { status: 503 }))).toBe("apiKeyCreateError");
    // A 2xx without the secret cannot be shown, so it is a failure too.
    expect(await failure(() => Response.json({ id: "key-9" }, { status: 201 }))).toBe("apiKeyCreateError");
  });

  test("revokes an API key and refreshes the key list, not on failure", async () => {
    let status = 204;
    const calls = stubRoutes(() => new Response(null, { status }));
    const queryClient = seededClient();
    queryClient.setQueryData(coderouterApiKeysQueryKey("team-1"), { keys: [] });
    const options = revokeApiKeyMutation(queryClient, "team-1");

    status = 404;
    await expect(runMutation(options, KEY_ID)).rejects.toThrow();
    expect(queryClient.getQueryState(coderouterApiKeysQueryKey("team-1"))?.isInvalidated).toBe(false);

    status = 204;
    await runMutation(options, KEY_ID);
    expect(calls[1].url).toBe(`/api/coderouter/api-keys/${KEY_ID}`);
    expect(calls[1].method).toBe("DELETE");
    expect(queryClient.getQueryState(coderouterApiKeysQueryKey("team-1"))?.isInvalidated).toBe(true);
  });
});

const originalFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = originalFetch;
});

type RouteCall = { url: string; method: string; headers: Headers; body: unknown };

/**
 * Serves the dashboard RPC calls of one test through the real coderouter
 * procedures. Only the REST handler behind `callRoute` is replaced: it records
 * the route request and answers with `reply()`.
 */
function stubRoutes(reply: () => Response) {
  const calls: RouteCall[] = [];
  routeReply = async (request) => {
    const url = new URL(request.url);
    const text = await request.text();
    calls.push({ url: `${url.pathname}${url.search}`, method: request.method, headers: request.headers, body: text ? JSON.parse(text) : undefined });
    return reply();
  };
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = input instanceof Request && init === undefined ? input : new Request(input, init);
    const { response } = await coderouterRpc.handle(request, {
      prefix: "/api/dashboard/rpc",
      context: { request, serverPrefetch: true },
    });
    return response ?? new Response("Not found", { status: 404 });
  }) as typeof fetch;
  return calls;
}

/** A client holding a loaded overview, so a test can see whether a write invalidated it. */
function seededClient() {
  const queryClient = new QueryClient();
  queryClient.setQueryData(coderouterOverviewQuery(undefined).queryKey, {} as never);
  return queryClient;
}

/**
 * Runs the full mutation lifecycle (mutationFn, then onSuccess or onError)
 * outside React. The factories close over their own client, so the observer's
 * client only hosts the mutation.
 */
function runMutation<Result, Variables>(
  options: UseMutationOptions<Result, Error, Variables>,
  variables: Variables,
): Promise<Result> {
  return new MutationObserver(new QueryClient(), options).mutate(variables);
}

function translator(namespace: string) {
  const root = valueAtPath(enMessages, namespace);
  return (key: string, values?: Record<string, unknown>) =>
    interpolate(String(valueAtPath(root, key)), values);
}

function valueAtPath(root: unknown, path: string): unknown {
  return path.split(".").reduce<unknown>((value, part) => {
    if (value && typeof value === "object" && part in value) {
      return (value as Record<string, unknown>)[part];
    }
    return path;
  }, root);
}

function interpolate(message: string, values?: Record<string, unknown>): string {
  if (!values) return message;
  return Object.entries(values).reduce((result, [key, value]) => {
    const plural = result.match(new RegExp(`\\{${key}, plural, ((?:=\\d+ \\{[^}]*\\} )?)one \\{([^}]*)\\} other \\{([^}]*)\\}\\}`));
    if (plural) {
      const exact = plural[1].match(/^=(\d+) \{([^}]*)\} $/);
      const form = exact && Number(exact[1]) === value
        ? exact[2]
        : value === 1 ? plural[2] : plural[3];
      return result.replace(plural[0], form.replaceAll("#", String(value)));
    }
    return result.replaceAll(`{${key}}`, String(value));
  }, message);
}
