// l10n-allow-file: transcript fixtures.
// A reply or another agent's message that says only "." draws nothing (Leo, 2026-11-02, on a lone
// "." under a received line: "these are all so stupid looking"); a person's own "." still draws.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { isBareAgentText, isVisiblyEmptyMessage } from "./visibleMessage";

const row = (kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: "r",
  version: 1,
  at: 0,
  kind,
  ...fields,
});
const received = (text: string) =>
  row("user", { text, incoming: { kind: "message", message: { name: "lane", text, raw: text } } });

test("an agent's empty, blank or lone-period words are bare", () => {
  for (const text of [undefined, "", "  \n", ".", " . ", "​"]) expect(isBareAgentText(text)).toBe(true);
  for (const text of ["..", "Done.", "ok", "…"]) expect(isBareAgentText(text)).toBe(false);
});

test("a reply of one period draws nothing; a real reply draws", () => {
  expect(isVisiblyEmptyMessage(row("assistant", { text: "." }))).toBe(true);
  expect(isVisiblyEmptyMessage(row("assistant", { text: " .\n" }))).toBe(true);
  expect(isVisiblyEmptyMessage(row("assistant", { text: "Done." }))).toBe(false);
});

test("another agent's empty or one-period message draws nothing; a message with words draws", () => {
  expect(isVisiblyEmptyMessage(received("."))).toBe(true);
  expect(isVisiblyEmptyMessage(received("   "))).toBe(true);
  expect(isVisiblyEmptyMessage(received("Green at 4f2a91c."))).toBe(false);
});

test("a person's own '.' prompt still draws, typed or relayed", () => {
  expect(isVisiblyEmptyMessage(row("user", { text: "." }))).toBe(false);
  const relayed = row("user", {
    text: ".",
    incoming: { kind: "message", message: { name: "guest", text: ".", raw: ".", fromPerson: true } },
  });
  expect(isVisiblyEmptyMessage(relayed)).toBe(false);
});

test("a one-period message that failed to deliver still draws its recovery", () => {
  expect(isVisiblyEmptyMessage({ ...received("."), failed: true })).toBe(false);
});
