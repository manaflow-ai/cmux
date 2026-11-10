// l10n-allow-file: test fixture prompts and replies, not shipped UI.
//
// A prompt's age and a reply's age read alike (Leo, 2026-11-08: "the timestamps for the agent and
// then the timestamps for the user, they need to be congruent ... Right now it's just, like in our
// app, only the user has that sort of relative time thing. The agent in ours only has the exact
// timestamp. But the exact timestamp should be, like, shown on hover"). One formatter (messageAge)
// writes both, the exact time is the tooltip of both, and every mounted label shares one page timer
// that holds nothing once no label can change.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { exactTime, messageAge, nextMessageAge } from "../src/agent-session/acpmux/conversation/relativeTime";
import { pageClocks } from "../src/ui/pageClock";
import { settleReact } from "./support/domTeardown";

const SECOND = 1_000;
const MINUTE = 60 * SECOND;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const NOW = new Date(2026, 10, 8, 11, 16).getTime();

test("one formatter: just now, minutes, hours to a day, days to a week, then the date", () => {
  const age = (ms: number) => messageAge(NOW - ms, NOW, "en-US");
  expect(age(0)).toBe("just now");
  expect(age(59 * SECOND)).toBe("just now");
  expect(age(MINUTE)).toBe("1 minute ago");
  expect(age(59 * MINUTE + 59 * SECOND)).toBe("59 minutes ago");
  expect(age(HOUR)).toBe("1 hour ago");
  expect(age(23 * HOUR + 59 * MINUTE)).toBe("23 hours ago");
  expect(age(DAY)).toBe("yesterday");
  expect(age(2 * DAY)).toBe("2 days ago");
  expect(age(7 * DAY - MINUTE)).toBe("6 days ago");
  // Past a week, the date: no year in this year, the year in another.
  expect(age(8 * DAY)).toBe("Oct 31");
  expect(messageAge(new Date(2025, 9, 18, 5, 41).getTime(), NOW, "en-US")).toBe("Oct 18, 2025");
  // A clock running ahead still reads as just sent.
  expect(messageAge(NOW + 5 * MINUTE, NOW, "en-US")).toBe("just now");
  // Other languages take Intl's words.
  expect(messageAge(NOW - 3 * HOUR, NOW, "de-DE")).toBe(
    new Intl.RelativeTimeFormat("de-DE", { numeric: "auto" }).format(-3, "hour"),
  );
});

test("labels wake at the first shared minute their words change, and never once they are a date", () => {
  const at = Date.UTC(2026, 9, 19, 9, 0, 23, 813);
  for (const seconds of [0, 59, 60, 89, 3599, 3600, 5399, 86399, 86400, 2 * 86400 + 7, 7 * 86400 - 61]) {
    const now = Math.floor((at + seconds * SECOND) / MINUTE) * MINUTE;
    const next = nextMessageAge(at, now);
    expect(next % MINUTE).toBe(0);
    expect(next).toBeGreaterThan(now);
    expect(messageAge(at, next - MINUTE, "en-US")).toBe(messageAge(at, now, "en-US"));
    expect(messageAge(at, next, "en-US")).not.toBe(messageAge(at, now, "en-US"));
  }
  // A date this year wakes once, at the new year, when its year appears; an earlier year's never.
  const newYear = new Date(new Date(at).getFullYear() + 1, 0, 1).getTime();
  expect(nextMessageAge(at, at + 7 * DAY)).toBe(newYear);
  expect(messageAge(at, newYear - MINUTE, "en-US")).not.toMatch(/\d{4}/);
  expect(messageAge(at, newYear, "en-US")).toMatch(/\b2026\b/);
  expect(nextMessageAge(at, at + 400 * DAY)).toBe(Infinity);
  expect(nextMessageAge(NaN, at)).toBe(Infinity);
});

const assistantRow = (at: number): AcpmuxRow => ({
  id: "a1",
  version: 1,
  at,
  kind: "assistant",
  text: "Pushed to the branch.",
});

test("an answer's footer (the exact-time shape) and a reply's own row read relative, the exact time on hover", async () => {
  const { TurnFooter } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  const { ReplyActions } = await import("../src/agent-session/acpmux/conversation/MessageActions");
  const at = Math.floor(Date.now() / MINUTE) * MINUTE - 10 * MINUTE - 5 * SECOND;
  const exact = exactTime(at, "en");
  const footer: AcpmuxRow = {
    id: "summary",
    version: 1,
    at,
    kind: "turnSummary",
    status: "completed",
    durationMs: 5_000,
    text: "Pushed to the branch.",
  };
  for (const markup of [
    renderToStaticMarkup(<TurnFooter row={footer} />),
    renderToStaticMarkup(<ReplyActions row={assistantRow(at)} />),
  ]) {
    const time = /<time class="cv-turn-time"([^>]*)>([^<]*)<\/time>/.exec(markup);
    expect(time?.[2]).toBe("10 minutes ago");
    expect(time?.[1]).toContain(`title="${exact}"`);
  }
});

test("a prompt's row has the same age and the same exact-time tooltip", async () => {
  const { PromptActions } = await import("../src/agent-session/acpmux/conversation/MessageActions");
  const at = Math.floor(Date.now() / MINUTE) * MINUTE - 10 * MINUTE - 5 * SECOND;
  const exact = exactTime(at, "en");
  const row: AcpmuxRow = { id: "u1", version: 1, at, kind: "user", text: "Ship it" };
  const markup = renderToStaticMarkup(<PromptActions row={row} text="Ship it" />);
  const time = /<time class="cv-user__time"([^>]*)>([^<]*)<\/time>/.exec(markup);
  expect(time?.[2]).toBe("10 minutes ago");
  expect(time?.[1]).toContain(`title="${exact}"`);
});

// Mounted labels: one timer for the whole list.
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT", "HTMLElement", "Element", "Node"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
  });
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

async function mount(ats: number[]) {
  const { createRoot } = await import("react-dom/client");
  const { MessageTime, ReplyTime } = await import("../src/agent-session/acpmux/conversation/MessageActions");
  const host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  act(() =>
    root!.render(
      <>
        {ats.map((at, index) =>
          index % 2 ? <ReplyTime key={index} at={at} /> : <MessageTime key={index} at={at} className="cv-user__time" />,
        )}
      </>,
    ),
  );
  return host;
}

test("forty mounted labels, prompts and replies, run exactly one timer; unmounted, none", async () => {
  const now = Date.now();
  const host = await mount(Array.from({ length: 40 }, (_, index) => now - index * 7 * MINUTE));
  expect(host.querySelectorAll("time").length).toBe(40);
  const clocks = pageClocks(dom.window.document);
  expect(clocks.running).toBe(1);
  expect(clocks.subscribers).toBe(40);
  act(() => root!.unmount());
  root = undefined;
  expect(pageClocks(dom.window.document)).toMatchObject({ running: 0, subscribers: 0 });
});

test("dates from an earlier year hold no timer", async () => {
  const lastYear = new Date(new Date().getFullYear() - 1, 5, 1).getTime();
  await mount([lastYear, lastYear - 30 * DAY, Date.now() - 400 * DAY, lastYear - 9 * DAY]);
  expect(pageClocks(dom.window.document).running).toBe(0);
});
