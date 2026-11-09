// l10n-allow-file: test fixtures.
// The card naming who wrote a changed line (AttributionCard.tsx): the newest writer first, older
// ones under it, this chat by name, another chat's turn as its cmux link.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { FALLBACK_LINK_SCHEME, setLinkScheme } from "../links";
import type { Attribution } from "./attribution";
import { AttributionCardContent } from "./AttributionCard";

const NOW = 10 * 60 * 60_000;
const writer = (turnId: string, at: number, extra: Partial<Attribution> = {}): Attribution => ({
  start: 1,
  end: 2,
  sessionId: "here",
  turnId,
  at,
  model: "Claude Opus 5.5",
  title: "Retry the upload",
  prompt: `Prompt of ${turnId}`,
  ...extra,
});

const render = (writers: Attribution[]) =>
  renderToStaticMarkup(
    <AttributionCardContent writers={writers} currentSessionId="here" onReveal={() => undefined} now={NOW} />,
  );

test("one writer of this chat: this chat, the model, the prompt and when, as a button to its turn", () => {
  const html = render([writer("t1", NOW - 5 * 60_000)]);
  expect(html).toContain("This chat");
  expect(html).not.toContain("Retry the upload");
  expect(html).toContain("Claude Opus 5.5");
  expect(html).toContain("Prompt of t1");
  expect(html).toContain("5 minutes ago");
  expect(html).toContain("<button");
  expect(html).not.toContain("Earlier");
});

test("two turns wrote the line: the newest in full, the older under Earlier", () => {
  const html = render([writer("new", NOW - 60_000), writer("old", NOW - 2 * 60 * 60_000, { model: "Sonnet" })]);
  expect(html.indexOf("Prompt of new")).toBeGreaterThan(-1);
  expect(html).not.toContain("Prompt of old");
  expect(html.indexOf("Earlier")).toBeGreaterThan(html.indexOf("Prompt of new"));
  expect(html).toContain("Sonnet · 2 hours ago");
});

test("another chat's writer is its title and a link to its turn", () => {
  setLinkScheme(undefined, FALLBACK_LINK_SCHEME);
  const html = render([writer("t9", NOW - 60_000, { sessionId: "there", title: "Rename keys" })]);
  expect(html).toContain("Rename keys");
  expect(html).toContain('href="cmux://session/there#turn-t9"');
  const untitled = render([writer("t9", NOW - 60_000, { sessionId: "there", title: undefined })]);
  expect(untitled).toContain("Untitled chat");
});

test("no writer draws nothing", () => {
  expect(render([])).toBe("");
});
