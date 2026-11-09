// l10n-allow-file: test fixture team and person names, not shipped UI.
// A Cloud start refused because the team picked in the team menu has no Cloud plan: the card names that
// team and offers the person's own (cloudPlanTeams.ts), from the host's `details` (CloudStartChat `teams`).
import { expect, test } from "bun:test";
import { cloudPlanTeamRefusal, isOwnTeam } from "./cloudPlanTeams";
import { startCloudChat, cloudStartKeys, type CloudStart } from "./cloudRun";
import { cloudStartEnded, type CloudStartProgress } from "./cloudStartProgress";

const leo = { userName: "Leo", userEmail: "leo@cmux.com" };
const teams = [
  { id: "t-cmux", name: "cmux" },
  { id: "t-leo", name: "Leo's Team" },
  { id: "t-acme", name: "Acme" },
];

test("a person's own team is the one named for them", () => {
  const person = { name: "Leo", email: "leo@cmux.com" };
  for (const name of ["Personal Team", "Personal", "Leo's Team", "leo’s team", "leo@cmux.com", "leo"])
    expect(isOwnTeam({ id: "x", name }, person)).toBe(true);
  for (const name of ["cmux", "Bob's Team", "Acme"]) expect(isOwnTeam({ id: "x", name }, person)).toBe(false);
});

test("a refusal in a team names it and offers the person's own team", () => {
  expect(cloudPlanTeamRefusal({ team: "t-cmux", teams, canSwitch: true, ...leo })).toEqual({
    team: "cmux",
    switchTo: { id: "t-leo", name: "Leo's Team" },
  });
  // Only one other team: that one, whatever it is named.
  expect(
    cloudPlanTeamRefusal({ team: "t-cmux", teams: [teams[0], { id: "t-me", name: "Moonbase" }], canSwitch: true }),
  ).toEqual({ team: "cmux", switchTo: { id: "t-me", name: "Moonbase" } });
  // Several teams and none named for them: the team is named, nothing is guessed.
  expect(
    cloudPlanTeamRefusal({ team: "t-cmux", teams: [teams[0], teams[2], { id: "t-b", name: "Beta" }], canSwitch: true }),
  ).toEqual({ team: "cmux" });
  // A device kept to one team cannot switch.
  expect(cloudPlanTeamRefusal({ team: "t-cmux", teams, canSwitch: false, ...leo })).toEqual({ team: "cmux" });
});

test("a refusal in the person's own account, or with no team named, keeps the plan's own card", () => {
  expect(cloudPlanTeamRefusal({ team: "t-leo", teams, canSwitch: true, ...leo })).toBeUndefined();
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
        details: { team: "t-cmux", teams, canSwitch: true, ...leo },
      }),
    { task: "fix it", cwd: "/w/paint" },
    "6f1c3a52-6c5e-4c38-9b3e-6b1d2a3c4d5e",
  );
  expect(answer).toMatchObject({ ok: false, code: "cloud_plan_required" });
  const starting: CloudStartProgress = { key: "k", task: "fix it", state: "starting" };
  const ended = cloudStartEnded(starting, "k", answer);
  expect(ended?.state).toBe("failed");
  expect(ended?.retryable).toBeUndefined();
  expect(ended?.planTeam).toEqual({ team: "cmux", switchTo: { id: "t-leo", name: "Leo's Team" } });
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
    { task: "fix it", cwd: "/w/paint", team: "t-leo" },
    "6f1c3a52-6c5e-4c38-9b3e-6b1d2a3c4d5e",
  );
  expect(sent[0]?.team).toBe("t-leo");
  // The send in the other team is a new start (its own key); the same prompt in the first team keeps its key.
  let next = 0;
  const keys = cloudStartKeys(undefined, () => 1, () => `key-${++next}`);
  const start: CloudStart = { task: "fix it", cwd: "/w/paint" };
  const first = keys.keyFor(start);
  keys.ended(start, { ok: false, code: "cloud_plan_required" });
  expect(keys.keyFor(start)).toBe(first);
  expect(keys.keyFor({ ...start, team: "t-leo" })).not.toBe(first);
});
