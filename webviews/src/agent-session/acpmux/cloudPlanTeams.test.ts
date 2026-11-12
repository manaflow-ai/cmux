// l10n-allow-file: test fixture team names, not shipped UI.
// A Cloud start refused because the team picked in the team menu has no Cloud plan: the card names that
// team and offers the person's own (cloudPlanTeams.ts), from the host's `details` (CloudAuth `planRefusalTeams`).
import { expect, test } from "bun:test";
import planTeamGallery from "./CloudPlanTeam.gallery";
import { cloudPlanTeamRefusal, isPersonalTeamId } from "./cloudPlanTeams";
import { startCloudChat, cloudStartKeys, cloudStartTeam, type CloudStart } from "./cloudRun";
import { cloudStartEnded, type CloudStartProgress } from "./cloudStartProgress";

const PERSONAL = "team_0123456789abcdef0123";
// The team menu as cmux#39950 lists it: the personal row first, then Stack's teams by their Stack ids.
const teams = [
  { id: PERSONAL, name: "Personal" },
  { id: "5b0e5c1e-2f1d-4c1a-9d1b-7f3a2b1c0d9e", name: "cmux" },
  { id: "c3d2e1f0-1a2b-4c3d-8e9f-0a1b2c3d4e5f", name: "Acme" },
];
const cmux = teams[1]!.id;

test("the person's own team is known by its id, never its name", () => {
  expect(isPersonalTeamId(PERSONAL)).toBe(true);
  for (const id of [cmux, "team_0123", "team_0123456789ABCDEF0123", "Personal"])
    expect(isPersonalTeamId(id)).toBe(false);
  // A Stack team named "Personal" (a legacy machine tenant) or "Leo's Team" is never offered.
  const named = [
    { id: cmux, name: "cmux" },
    { id: "a1b2c3d4-0000-4000-8000-000000000001", name: "Personal" },
    { id: "a1b2c3d4-0000-4000-8000-000000000002", name: "Leo's Team" },
  ];
  expect(cloudPlanTeamRefusal({ team: cmux, teams: named, canSwitch: true })).toEqual({ team: "cmux" });
});

test("a refusal in a team names it and offers the person's own team", () => {
  expect(cloudPlanTeamRefusal({ team: cmux, teams, canSwitch: true })).toEqual({
    team: "cmux",
    switchTo: { id: PERSONAL, name: "Personal" },
  });
  // A device kept to one team cannot switch.
  expect(cloudPlanTeamRefusal({ team: cmux, teams, canSwitch: false })).toEqual({ team: "cmux" });
});

test("a refusal in the person's own account, or with no team named, keeps the plan's own card", () => {
  expect(cloudPlanTeamRefusal({ team: PERSONAL, teams, canSwitch: true })).toBeUndefined();
  expect(cloudPlanTeamRefusal({ teams })).toBeUndefined();
  expect(cloudPlanTeamRefusal(undefined)).toBeUndefined();
  expect(cloudPlanTeamRefusal({ team: "t-gone", teams })).toBeUndefined();
});

test("the host's plan refusal ends the start as a final team state, never a retry", async () => {
  const answer = await startCloudChat(
    () =>
      Promise.reject({
        code: "cloud_plan_required",
        userMessage: "Cloud machines need a Pro plan.",
        details: { team: cmux, teams, canSwitch: true },
      }),
    { task: "fix it", cwd: "/w/paint" },
    "6f1c3a52-6c5e-4c38-9b3e-6b1d2a3c4d5e",
  );
  expect(answer).toMatchObject({ ok: false, code: "cloud_plan_required" });
  const starting: CloudStartProgress = { key: "k", task: "fix it", state: "starting" };
  const ended = cloudStartEnded(starting, "k", answer);
  expect(ended?.state).toBe("failed");
  expect(ended?.retryable).toBeUndefined();
  expect(ended?.planTeam).toEqual({ team: "cmux", switchTo: { id: PERSONAL, name: "Personal" } });
  // Another failure carries no team state.
  expect(cloudStartEnded(starting, "k", { ok: false, code: "cloud_start_failed" })?.planTeam).toBeUndefined();
});

test("Switch to <team> sends the team with the start, under a new key", async () => {
  const sent: Record<string, unknown>[] = [];
  await startCloudChat(
    (_method, params) => {
      sent.push(params);
      return Promise.resolve({});
    },
    { task: "fix it", cwd: "/w/paint", team: PERSONAL },
    "6f1c3a52-6c5e-4c38-9b3e-6b1d2a3c4d5e",
  );
  expect(sent[0]?.team).toBe(PERSONAL);
  // The send in the other team is a new start (its own key); the same prompt in the first team keeps its key.
  let next = 0;
  const keys = cloudStartKeys(
    undefined,
    () => 1,
    () => `key-${++next}`,
  );
  const start: CloudStart = { task: "fix it", cwd: "/w/paint" };
  const first = keys.keyFor(start);
  keys.ended(start, { ok: false, code: "cloud_plan_required" });
  expect(keys.keyFor(start)).toBe(first);
  expect(keys.keyFor({ ...start, team: PERSONAL })).not.toBe(first);
});

test("Retry after a switched send keeps its team, so it reaches that send's machine (cmux#39928 F2)", () => {
  const team = cloudStartTeam();
  team.pick(PERSONAL);
  let next = 0;
  const keys = cloudStartKeys(
    undefined,
    () => 1,
    () => `key-${++next}`,
  );
  const start: CloudStart = { task: "fix it", cwd: "/w/paint" };
  const switched = keys.keyFor({ ...start, ...(team.forSend() ? { team: team.forSend() } : {}) });
  // The switched send failed after making its machine: the card's Retry sends again with the same team.
  team.ended({ ok: false, code: "cloud_start_failed", retryable: true });
  expect(team.forSend()).toBe(PERSONAL);
  expect(keys.keyFor({ ...start, ...(team.forSend() ? { team: team.forSend() } : {}) })).toBe(switched);
  // The chat opened (or went to this Mac), or the person left Cloud or the chat: no team for a later send.
  team.ended({ ok: true });
  expect(team.forSend()).toBeUndefined();
  team.pick(PERSONAL);
  team.ended({ ok: false, code: "run_on_this_mac" });
  expect(team.forSend()).toBeUndefined();
  team.pick(PERSONAL);
  team.reset();
  expect(team.forSend()).toBeUndefined();
});

test("a start the host refused while the team was still switching says so, with Retry (cmux#39928 F3)", () => {
  const starting: CloudStartProgress = { key: "k", task: "fix it", state: "starting" };
  const ended = cloudStartEnded(starting, "k", {
    ok: false,
    code: "cloud_team_switching",
    message: "cloud_team_switching",
    retryable: true,
  });
  expect(ended?.retryable).toBe(true);
  expect(ended?.message).toBe("Your team is still switching. Send again in a moment.");
});

test("the gallery's card look has room for its open checklist and the buttons under it (cmux#39928 F1)", () => {
  // The failed checklist opens on its own (CloudStartView): at the entry's 260 px it hid the team line and buttons.
  const variants = planTeamGallery.variants as Record<string, { height?: number }>;
  expect(variants.card?.height ?? planTeamGallery.height ?? 0).toBeGreaterThanOrEqual(520);
});
