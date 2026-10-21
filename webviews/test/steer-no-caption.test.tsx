// A steered message looks like any other sent message: no "Steering · The agent reads it when its
// current step ends" sentence under it (Leo, 2026-10-20: "wtf have we removed this yet"). While the
// agent has not read it, only a quiet clock and Send now show (PendingSteer.tsx); the words that
// caption used are gone from the catalog, so no row can draw them again.
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
  expect(html).not.toMatch(/Steering|reads it when|current step ends/);
});

test("a waiting steer without a prompt id shows the clock alone", () => {
  const html = renderToStaticMarkup(<PendingSteer row={steer({ steer: "waiting" })} send={send} />);
  expect(text(html)).toBe("");
});

test("the Steering caption's words are gone from the catalog", async () => {
  const catalog = await Bun.file(new URL("../src/agent-session/acpmux/Localizable.xcstrings", import.meta.url)).json();
  expect(catalog.strings["steer.waiting"]).toBeUndefined();
  expect(catalog.strings["steer.waitingDetail"]).toBeUndefined();
  const english = Object.values(
    catalog.strings as Record<string, { localizations?: { en?: { stringUnit?: { value?: string } } } }>,
  )
    .map((entry) => entry.localizations?.en?.stringUnit?.value ?? "")
    .filter((value) => /reads it when its current step ends/.test(value));
  expect(english).toEqual([]);
});
