// The status-outside-the-dot detector (scripts/check-status-outside-dot.ts, RFD 0128): a dot item's words
// drawn anywhere but the composer status dot fail, unless ALLOWED says why they are not a status row.
import { expect, test } from "bun:test";
import { dotKinds, findAll, findInSource, rules, words } from "../scripts/check-status-outside-dot";

test("the webviews draw no composer status outside the dot", () => {
  const { findings, stale } = findAll();
  expect(findings.map((f) => `${f.file}:${f.line} ${f.kind} ${f.key}`)).toEqual([]);
  expect(stale).toEqual([]);
});

test("the dot's kinds are read from the model", () => {
  expect(
    dotKinds(`const KINDS: ReadonlySet<string> = new Set<StatusKind>([\n  "machineLink",\n  "sendsHeld",\n]);`),
  ).toEqual(["machineLink", "sendsHeld"]);
});

test("words set aside placeholders, punctuation and case", () => {
  expect(words("Reconnecting to {subject}…")).toBe("reconnecting to");
  expect(words("Restoring sessions… {time}")).toBe(words("Restoring sessions…"));
});

const catalog = new Map([
  ["status.sendsHeld.held", "Sending when ready"],
  ["status.queuePaused.paused", "Queue paused"],
  ["composer.sendingWhenReady", "Sending when ready"],
  ["fresh.pausedRow", "Queue paused."],
  ["other.thing", "Something else"],
]);
const r = rules(catalog, ["sendsHeld", "queuePaused"]);

test("a planted row repeating an item's words fails; other copy passes", () => {
  const text = `
const a = t("fresh.pausedRow");
const b = t("other.thing");
const c = t("status.sendsHeld.held");
`;
  expect(
    findInSource("agent-session/acpmux/NewRow.tsx", text, r).map((f) =>
      `${f.line} ${f.kind} ${f.key} ${f.item ?? ""}`.trim(),
    ),
  ).toEqual(["2 dot-words fresh.pausedRow status.queuePaused.paused", "4 dot-key status.sendsHeld.held"]);
});

test("the dot's own files, ALLOWED rows, tests and galleries pass", () => {
  expect(findInSource("agent-session/acpmux/ComposerStatusDot.tsx", `t("status.sendsHeld.held")`, r)).toEqual([]);
  expect(findInSource("agent-session/acpmux/Composer.tsx", `t("composer.sendingWhenReady")`, r)).toEqual([]);
  expect(findInSource("agent-session/acpmux/Other.tsx", `t("composer.sendingWhenReady")`, r)).toHaveLength(1);
  expect(findInSource("agent-session/acpmux/Other.gallery.tsx", `t("composer.sendingWhenReady")`, r)).toEqual([]);
  expect(findInSource("agent-session/acpmux/Other.test.tsx", `t("status.sendsHeld.held")`, r)).toEqual([]);
});
