// A steered message looks like any other sent message: no "Steering · The agent reads it when its
// current step ends" sentence under it while it waits (Leo, 2026-10-20: "wtf have we removed this
// yet"), and no "Steered · the agent read it" once read (Leo, 2026-10-21: "I THOUGHT WE REMOVED
// THAT"). While the agent has not read it, only plain Send now shows (PendingSteer.tsx);
// once read, only the read check every prompt has (MessageActions.tsx ReadReceipt). The words
// those captions used are gone from the catalog, so no row can draw them again.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { PendingSteer } from "../src/agent-session/acpmux/conversation/PendingSteer";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const steer = (extra: Partial<AcpmuxRow>): AcpmuxRow => ({
  id: "u1",
  kind: "user",
  version: 1,
  at: 1_000,
  text: "it's literally right there dont duplicate work",
  ...extra,
});
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
const send = async () => true;

test("a waiting steer shows Send now and no sentence", () => {
  const html = renderToStaticMarkup(
    <PendingSteer row={steer({ steer: "waiting", steerPromptId: "p1" })} send={send} />,
  );
  expect(text(html)).toBe("Send now");
  expect(html).not.toContain("Clock");
  expect(html).not.toMatch(/Steering|reads it when|current step ends/);
});

test("a waiting steer without a prompt id shows the clock alone", () => {
  const html = renderToStaticMarkup(<PendingSteer row={steer({ steer: "waiting" })} send={send} />);
  expect(text(html)).toBe("");
});

test("the Steering and Steered captions' words are gone from the catalog", async () => {
  const catalog = await Bun.file(new URL("../src/agent-session/acpmux/Localizable.xcstrings", import.meta.url)).json();
  expect(catalog.strings["steer.waiting"]).toBeUndefined();
  expect(catalog.strings["steer.waitingDetail"]).toBeUndefined();
  // Nor the "Steered · the agent read it" line a read steer once had (SteerMark.tsx, removed in #22773).
  expect(catalog.strings["steer.landed"]).toBeUndefined();
  const english = Object.values(
    catalog.strings as Record<string, { localizations?: { en?: { stringUnit?: { value?: string } } } }>,
  )
    .map((entry) => entry.localizations?.en?.stringUnit?.value ?? "")
    .filter((value) => /reads it when its current step ends|^Steered\b/.test(value));
  expect(english).toEqual([]);
});
