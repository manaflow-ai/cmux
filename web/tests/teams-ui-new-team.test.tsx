import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";
import { teamsNextIntlMock } from "./helpers/teams-ui-intl";

mock.module("next-intl", teamsNextIntlMock);
mock.module("../i18n/navigation", () => ({
  Link: ({ href, children, className }: { href: string; children: React.ReactNode; className?: string }) => (
    <a href={href} className={className}>{children}</a>
  ),
  useRouter: () => ({ push: () => undefined }),
}));
mock.module("@tanstack/react-query", () => ({
  useMutation: () => ({ mutate: () => undefined, isPending: false, isError: false }),
  useQueryClient: () => ({}),
  useQuery: () => ({}),
}));

const { NewTeamFlow, newTeamFlowReducer } = await import("../app/[locale]/dashboard/teams/new/new-team-flow");
const { validateTeamName, teamCheckoutHref, TEAM_NAME_MAX_LENGTH } = await import(
  "../app/[locale]/dashboard/teams/team-logic"
);

const team = { id: "team 1", displayName: "Acme" };

describe("new team flow steps", () => {
  test("moves name -> plan -> invite and back to plan only", () => {
    const plan = newTeamFlowReducer({ step: "name" }, { type: "created", team });
    expect(plan).toEqual({ step: "plan", team });
    const invite = newTeamFlowReducer(plan, { type: "choseFree" });
    expect(invite).toEqual({ step: "invite", team });
    expect(newTeamFlowReducer(invite, { type: "backToPlan" })).toEqual({ step: "plan", team });
  });

  test("ignores actions that do not belong to the current step", () => {
    const name = { step: "name" } as const;
    expect(newTeamFlowReducer(name, { type: "choseFree" })).toBe(name);
    expect(newTeamFlowReducer(name, { type: "backToPlan" })).toBe(name);
    const plan = { step: "plan", team } as const;
    // The team already exists; a second create must not replace it.
    expect(newTeamFlowReducer(plan, { type: "created", team: { id: "other", displayName: "Other" } })).toBe(plan);
  });

  test("validates the team name before creating", () => {
    expect(validateTeamName("  Acme  ")).toEqual({ ok: true, value: "Acme" });
    expect(validateTeamName("   ")).toEqual({ ok: false, reason: "empty" });
    expect(validateTeamName("x".repeat(TEAM_NAME_MAX_LENGTH))).toEqual({ ok: true, value: "x".repeat(TEAM_NAME_MAX_LENGTH) });
    expect(validateTeamName("x".repeat(TEAM_NAME_MAX_LENGTH + 1))).toEqual({ ok: false, reason: "tooLong" });
  });

  test("renders the name step first", () => {
    const html = renderToStaticMarkup(<NewTeamFlow />);
    expect(html).toContain("Name your team");
    expect(html).toContain('aria-current="step"');
    expect(html).not.toContain("Choose a plan");
  });

  test("offers Free and a full-navigation Team checkout for the created team", () => {
    const html = renderToStaticMarkup(<NewTeamFlow initialState={{ step: "plan", team }} />);
    expect(html).toContain("Choose a plan for Acme");
    expect(html).toContain("Continue with Free");
    expect(html).toContain("$60 per seat per month");
    expect(teamCheckoutHref(team.id)).toBe("/api/billing/checkout?plan=team&teamId=team+1");
    expect(html).toContain('href="/api/billing/checkout?plan=team&amp;teamId=team+1"');
  });

  test("the invite step can finish without inviting anyone", () => {
    const html = renderToStaticMarkup(<NewTeamFlow initialState={{ step: "invite", team }} />);
    expect(html).toContain("Invite people to Acme");
    expect(html).toContain("Send invitations");
    expect(html).toContain("Create link");
    expect(html).toContain("Go to team");
  });
});
