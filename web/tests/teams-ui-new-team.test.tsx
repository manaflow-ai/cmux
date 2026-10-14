import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { ReactNode } from "react";
import { withDashboardRouter } from "./helpers/dashboard-router";
import { teamsNextIntlMock } from "./helpers/teams-ui-intl";

mock.module("next-intl", teamsNextIntlMock);

const { NewTeamFlow, newTeamFlowReducer } = await import("../dashboard-app/screens/teams/new-team-flow");
const { validateTeamName, teamCheckoutHref, TEAM_NAME_MAX_LENGTH } = await import(
  "../dashboard-app/screens/teams/team-logic"
);

const team = { id: "team 1", displayName: "Acme" };

async function render(element: ReactNode): Promise<string> {
  return renderToStaticMarkup((await withDashboardRouter(element, "/dashboard/teams/new")).element);
}

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

  test("renders the name step first", async () => {
    const html = await render(<NewTeamFlow />);
    expect(html).toContain("Name your team");
    expect(html).toContain('aria-current="step"');
    expect(html).not.toContain("Choose a plan");
    expect(html).toContain('href="/dashboard/teams"');
  });

  test("offers Free and a full-navigation Team checkout for the created team", async () => {
    const html = await render(<NewTeamFlow initialState={{ step: "plan", team }} />);
    expect(html).toContain("Choose a plan for Acme");
    expect(html).toContain("Continue with Free");
    expect(html).toContain("$60 per seat per month");
    expect(teamCheckoutHref(team.id)).toBe("/api/billing/checkout?plan=team&teamId=team+1");
    expect(html).toContain('href="/api/billing/checkout?plan=team&amp;teamId=team+1"');
  });

  test("the plan step says seats follow the member count", async () => {
    const html = await render(<NewTeamFlow initialState={{ step: "plan", team }} />);

    // Seats are not soft: the subscription quantity follows the member count,
    // so this line must not go back to offering to add seats later.
    expect(html).toContain(
      "Seats follow your member count: each member is billed, and the total updates when people join or leave."
    );
    expect(html).not.toContain("add seats later");
  });

  test("the invite step can finish without inviting anyone", async () => {
    const html = await render(<NewTeamFlow initialState={{ step: "invite", team }} />);
    expect(html).toContain("Invite people to Acme");
    expect(html).toContain("Send invitations");
    expect(html).toContain("Create link");
    expect(html).toContain("Go to team");
  });
});
