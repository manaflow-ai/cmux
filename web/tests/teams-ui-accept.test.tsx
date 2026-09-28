import { afterEach, describe, expect, mock, test } from "bun:test";
import { QueryClient } from "@tanstack/react-query";
import { renderToStaticMarkup } from "react-dom/server";
import { withDashboardRouter } from "./helpers/dashboard-router";
import { teamsNextIntlMock } from "./helpers/teams-ui-intl";


mock.module("next-intl", teamsNextIntlMock);
mock.module("@hexclave/next", () => ({
  useStackApp: () => ({ signOut: async () => undefined, getTeamInvitationDetails: async () => ({ status: "ok", data: { teamDisplayName: "Acme" } }) }),
}));

const { AcceptInvite, acceptAndOpenTeam, acceptInviteState, acceptReturnPath, invitationDetailsFromResult } = await import(
  "../dashboard-app/screens/teams/accept-invite"
);
const { InviteResponseCard } = await import("../dashboard-app/screens/teams/invite-response");
const { TeamApiError } = await import("../dashboard-app/queries/teams");

const originalFetch = globalThis.fetch;
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
  test("keeps the invitation code in the page's return path", () => {
    // The shell sends a signed-out visitor to sign-in with the full URL; the
    // switch-account button uses this path.
    expect(acceptReturnPath("abc 123")).toBe("/dashboard/team/accept?code=abc+123");
  });

  test("shows the team name and a Join button to a signed-in viewer", async () => {
    const queryClient = new QueryClient();
    queryClient.setQueryData(["team-invitation-details", "abc"], { status: "ok", teamName: "Acme" });
    const { element } = await withDashboardRouter(
      <AcceptInvite code="abc" viewerEmail="ada@x.com" />,
      "/dashboard/team/accept?code=abc",
      queryClient,
    );
    const html = renderToStaticMarkup(element);
    expect(html).toContain('data-testid="invite-ready"');
    expect(html).toContain("Join Acme");
    expect(html).toContain("Join team");
    expect(html).toContain("Signed in as ada@x.com");
  });

  test("a missing code renders the invalid state with a link to teams", async () => {
    const { element } = await withDashboardRouter(<AcceptInvite code="" viewerEmail="ada@x.com" />);
    const html = renderToStaticMarkup(element);
    expect(html).toContain('data-testid="invite-invalid"');
    expect(html).toContain('href="/dashboard/teams"');
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
    const { teamApi } = await import("../dashboard-app/queries/teams");
    const visited: string[] = [];
    let refreshed = false;

    const error = await acceptAndOpenTeam("abc", {
      accept: teamApi.accept,
      afterJoin: async () => {
        refreshed = true;
      },
      openTeam: (teamId) => visited.push(teamId),
    });

    expect(error).toBeNull();
    expect(new URL(requests[0].url).pathname).toBe("/api/teams/accept");
    expect(await requests[0].json()).toEqual({ code: "abc" });
    expect(refreshed).toBe(true);
    expect(visited).toEqual(["team 9"]);
  });

  test("a refused join reports the error code and does not navigate", async () => {
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ error: { code: "email_mismatch", message: "x" } }), { status: 409 })) as typeof fetch;
    const { teamApi } = await import("../dashboard-app/queries/teams");
    const visited: string[] = [];
    const error = await acceptAndOpenTeam("abc", {
      accept: teamApi.accept,
      afterJoin: async () => undefined,
      openTeam: (teamId) => visited.push(teamId),
    });
    expect(error).toBeInstanceOf(TeamApiError);
    expect((error as InstanceType<typeof TeamApiError>).code).toBe("email_mismatch");
    expect(visited).toEqual([]);
  });
});
