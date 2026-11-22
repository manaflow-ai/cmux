// l10n-allow-file: test fixtures.
// The skill offer card's state (skillOffer.ts), derived from acpmux's `skill_offer` record and the
// `skill_resolved` record or `_acpmux/skill_resolve` answer that settles it.
import { expect, test } from "bun:test";
import {
  settleSkillOffer,
  skillDraftProblems,
  skillOfferFromRecord,
  skillRequestFailed,
  skillRequestStarted,
  skillSteps,
} from "./skillOffer";

const BODY = "## Steps\n\n1. Install.\n2. Run bun test.\n\n## Commands\n\n- `bun test`\n";
const RECORD = {
  offerId: "s1",
  name: "run-webview-tests",
  description: "Use when asked to run the webview tests.",
  body: BODY,
  count: 3,
  chats: [
    { sessionId: "a", prompt: "Run the tests." },
    { sessionId: "b", prompt: "  Run   the\ntests again. " },
    { sessionId: "c", prompt: "x".repeat(400) },
  ],
  drafted: "harness",
  harness: "claude",
};
const offer = () => skillOfferFromRecord(RECORD)!;

test("an offer record draws its draft, count and source chats", () => {
  const skill = offer();
  expect(skill).toMatchObject({
    offerId: "s1",
    name: "run-webview-tests",
    description: "Use when asked to run the webview tests.",
    body: BODY.trim(),
    count: 3,
    drafted: "harness",
    harness: "claude",
  });
  expect(skill.chats.map((chat) => chat.prompt)).toEqual(["Run the tests.", "Run the tests again.", "x".repeat(160)]);
  expect(skill.outcome).toBeUndefined();
  expect(skillOfferFromRecord({ ...RECORD, drafted: "shapes", harness: undefined })).toMatchObject({
    drafted: "shapes",
  });
});

test("a record the card cannot draw is skipped", () => {
  expect(skillOfferFromRecord(undefined)).toBeUndefined();
  expect(skillOfferFromRecord("skill")).toBeUndefined();
  expect(skillOfferFromRecord({ ...RECORD, offerId: "" })).toBeUndefined();
  expect(skillOfferFromRecord({ ...RECORD, offerId: 4 })).toBeUndefined();
  expect(skillOfferFromRecord({ ...RECORD, name: " " })).toBeUndefined();
  expect(skillOfferFromRecord({ ...RECORD, body: "" })).toBeUndefined();
  // Bad chats are dropped, a missing count is at least three, a description is one line.
  const loose = skillOfferFromRecord({
    ...RECORD,
    chats: [null, { prompt: "no id" }],
    count: "3",
    description: "a\nb",
  })!;
  expect(loose.chats).toEqual([]);
  expect(loose.count).toBe(3);
  expect(loose.description).toBe("a");
  expect(loose.drafted).toBe("harness");
});

test("a save or a dismissal settles the offer once; another offer's or a bad one is ignored", () => {
  const saved = settleSkillOffer(offer(), {
    offerId: "s1",
    action: "save",
    name: "run-tests",
    path: ".claude/skills/run-tests/SKILL.md",
  });
  expect(saved.outcome).toEqual({ action: "save", name: "run-tests", path: ".claude/skills/run-tests/SKILL.md" });
  expect(settleSkillOffer(saved, { offerId: "s1", action: "dismiss" })).toBe(saved);
  const base = offer();
  expect(settleSkillOffer(base, { offerId: "s2", action: "save" })).toBe(base);
  expect(settleSkillOffer(base, { offerId: "s1", action: "keep" })).toBe(base);
  expect(settleSkillOffer(base, null)).toBe(base);
  // A save that names nothing keeps the draft's name.
  expect(settleSkillOffer(base, { action: "save" }).outcome).toEqual({ action: "save", name: "run-webview-tests" });
  expect(settleSkillOffer(base, { offerId: "s1", action: "dismiss" }).outcome).toEqual({ action: "dismiss" });
});

test("a request in flight holds the buttons; a failed one frees them with the daemon's message", () => {
  const waiting = skillRequestStarted(offer(), "save");
  expect(waiting.busy).toBe("save");
  const failed = skillRequestFailed(waiting, "a skill named run-webview-tests already exists");
  expect(failed.busy).toBeUndefined();
  expect(failed.error).toBe("a skill named run-webview-tests already exists");
  expect(skillRequestStarted(failed, "save").error).toBeUndefined();
  const settled = settleSkillOffer(failed, { action: "dismiss" });
  expect(settled.error).toBeUndefined();
  expect(settled.busy).toBeUndefined();
});

test("an edited draft is checked against the daemon's limits", () => {
  const good = { name: "run-tests", description: "When to run tests.", body: BODY };
  expect(skillDraftProblems(good)).toEqual({});
  expect(skillDraftProblems({ ...good, name: "Run Tests" })).toEqual({ name: true });
  expect(skillDraftProblems({ ...good, name: "-run" })).toEqual({ name: true });
  expect(skillDraftProblems({ ...good, name: "a".repeat(65) })).toEqual({ name: true });
  expect(skillDraftProblems({ ...good, name: "a".repeat(64) })).toEqual({});
  expect(skillDraftProblems({ ...good, description: "two\nlines" })).toEqual({ description: true });
  expect(skillDraftProblems({ ...good, description: "d".repeat(301) })).toEqual({ description: true });
  expect(skillDraftProblems({ ...good, body: " " })).toEqual({ body: true });
  expect(skillDraftProblems({ ...good, body: "b".repeat(16 * 1024 + 1) })).toEqual({ body: true });
});

test("the steps are the numbered lines under ## Steps", () => {
  expect(skillSteps(BODY)).toEqual(["Install.", "Run bun test."]);
  expect(skillSteps("1) One\n2. Two\n- not a step")).toEqual(["One", "Two"]);
});
