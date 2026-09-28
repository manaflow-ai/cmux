import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";
import { renderSettled } from "./helpers/render-settled";
import { teamsNextIntlMock } from "./helpers/teams-ui-intl";

let redirectedTo: string | null = null;
let sessionUser: { primaryEmail: string | null } | null = { primaryEmail: "ada@x.com" };
let requestedReturnPath: string | null = null;

mock.module("next-intl", teamsNextIntlMock);
mock.module("../i18n/navigation", () => ({
  Link: ({ href, children, className }: { href: string; children: React.ReactNode; className?: string }) => (
    <a href={href} className={className}>{children}</a>
  ),
  useRouter: () => ({ push: () => undefined }),
}));
mock.module("@hexclave/next", () => ({
  useStackApp: () => ({ signOut: async () => undefined, getTeamInvitationDetails: async () => ({ status: "ok", data: { teamDisplayName: "Acme" } }) }),
}));
mock.module("@tanstack/react-query", () => ({
  useQuery: () => ({ data: { status: "ok", teamName: "Acme" }, isError: false }),
  useQueryClient: () => ({ invalidateQueries: async () => undefined }),
  useMutation: () => ({}),
}));
// The real gate redirects a missing session; model that here so the test
// checks what the page asks it to preserve.
mock.module("../app/lib/dashboard-auth", () => ({
  loadDashboardSection: async (_locale: string, returnPath: string) => {
    requestedReturnPath = returnPath;
    if (!sessionUser) {
      redirectedTo = `/handler/sign-in?after_auth_return_to=${encodeURIComponent(returnPath)}`;
      throw new Error(`redirect:${redirectedTo}`);
    }
    return { kind: "user", user: { id: "user-1", ...sessionUser } };
  },
  dashboardAuthorizationSignInHref: (_locale: string, path: string) => `/handler/sign-in?to=${path}`,
}));

const { default: AcceptPage } = await import("../app/[locale]/dashboard/team/accept/page");
const { acceptAndOpenTeam, acceptInviteState, invitationDetailsFromResult } = await import(
  "../app/[locale]/dashboard/team/accept/accept-invite"
);
const { InviteResponseCard } = await import("../app/[locale]/dashboard/team/accept/invite-response");
const { TeamApiError } = await import("../app/[locale]/dashboard/teams/team-api");

const originalFetch = globalThis.fetch;
beforeEach(() => {
  redirectedTo = null;
  requestedReturnPath = null;
  sessionUser = { primaryEmail: "ada@x.com" };
});
afterEach(() => {
  globalThis.fetch = originalFetch;
});

function renderCard(state: Parameters<typeof InviteResponseCard>[0]["state"], viewerEmail: string | null = "ada@x.com") {
  return renderToStaticMarkup(
    <InviteResponseCard
      state={state}
      viewerEmail={viewerEmail}
      onJoin={() => undefined}
      returnPath="/dashboard/team/accept?code=abc"
      locale="en"
    />,
  );
}

describe("accept invitation page", () => {
  test("sends a signed-out visitor to sign-in with the invitation code preserved", async () => {
    sessionUser = null;
    const page = AcceptPage({
      params: Promise.resolve({ locale: "en" }),
      searchParams: Promise.resolve({ code: "abc 123" }),
    });
    await expect(renderSettled(page)).rejects.toThrow("redirect:");
    expect(requestedReturnPath).toBe("/dashboard/team/accept?code=abc+123");
    expect(redirectedTo).toContain(encodeURIComponent("/dashboard/team/accept?code=abc+123"));
  });

  test("shows the team name and a Join button to a signed-in viewer", async () => {
    const html = await renderSettled(
      AcceptPage({ params: Promise.resolve({ locale: "en" }), searchParams: Promise.resolve({ code: "abc" }) }),
    );
    expect(html).toContain('data-testid="invite-ready"');
    expect(html).toContain("Join Acme");
    expect(html).toContain("Join team");
    expect(html).toContain("Signed in as ada@x.com");
  });

  test("explains an email mismatch and offers to switch accounts", () => {
    const state = acceptInviteState({ code: "abc", details: { status: "ok", teamName: "Acme" }, joinFailure: "email_mismatch" });
    expect(state).toEqual({ kind: "mismatch" });
    const html = renderCard(state);
    expect(html).toContain('data-testid="invite-mismatch"');
    expect(html).toContain("You are signed in as ada@x.com");
    expect(html).toContain("Sign out and switch account");
    expect(html).not.toContain("Join team");
  });

  test("maps Stack's preview refusals and missing codes", () => {
    expect(invitationDetailsFromResult({ status: "error", error: { errorCode: "TEAM_INVITATION_EMAIL_MISMATCH" } })).toEqual({ status: "mismatch" });
    expect(invitationDetailsFromResult({ status: "error", error: { errorCode: "VERIFICATION_CODE_EXPIRED" } })).toEqual({ status: "invalid" });
    expect(acceptInviteState({ code: "", details: undefined, joinFailure: null })).toEqual({ kind: "invalid" });
    expect(acceptInviteState({ code: "abc", details: undefined, joinFailure: null })).toEqual({ kind: "loading" });
    expect(acceptInviteState({ code: "abc", details: { status: "unknown" }, joinFailure: null })).toEqual({ kind: "ready", teamName: null });
    const html = renderCard(acceptInviteState({ code: "abc", details: undefined, joinFailure: "invitation_invalid" }));
    expect(html).toContain("This invitation is no longer valid");
  });

  test("joining posts the code and opens the team", async () => {
    const requests: Request[] = [];
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      requests.push(new Request(new URL(String(input), "https://cmux.test"), init));
      return new Response(JSON.stringify({ teamId: "team 9" }), { status: 200 });
    }) as typeof fetch;
    const { teamApi } = await import("../app/[locale]/dashboard/teams/team-api");
    const visited: string[] = [];
    let refreshed = false;

    const error = await acceptAndOpenTeam("abc", {
      accept: teamApi.accept,
      afterJoin: async () => {
        refreshed = true;
      },
      navigate: (href) => visited.push(href),
    });

    expect(error).toBeNull();
    expect(new URL(requests[0].url).pathname).toBe("/api/teams/accept");
    expect(await requests[0].json()).toEqual({ code: "abc" });
    expect(refreshed).toBe(true);
    expect(visited).toEqual(["/dashboard/teams/team%209"]);
  });

  test("a refused join reports the error code and does not navigate", async () => {
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ error: { code: "email_mismatch", message: "x" } }), { status: 409 })) as typeof fetch;
    const { teamApi } = await import("../app/[locale]/dashboard/teams/team-api");
    const visited: string[] = [];
    const error = await acceptAndOpenTeam("abc", {
      accept: teamApi.accept,
      afterJoin: async () => undefined,
      navigate: (href) => visited.push(href),
    });
    expect(error).toBeInstanceOf(TeamApiError);
    expect((error as InstanceType<typeof TeamApiError>).code).toBe("email_mismatch");
    expect(visited).toEqual([]);
  });
});
