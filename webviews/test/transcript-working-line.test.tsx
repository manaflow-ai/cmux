// l10n-allow-file: test fixture tool titles, not shipped UI.
// The running turn's status line, as Claude desktop draws it (#21604 row 2,
// transcript-task-list-in-progress.png): what the agent is doing now. While a tool call runs the
// line names it and keeps the turn's time beside it; between calls it reads "Working for 42s" as
// before, and before any work "Thinking". No mark blinks before any of them (Leo, 2026-10-20: the
// three pulsing dots were "the blinking ascii"; the ticking time says the turn is alive).
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ActivityLine } from "../src/agent-session/acpmux/conversation/ActivityLine";
import { pageClocks } from "../src/ui/pageClock";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { translate } from "../src/agent-session/acpmux/i18n";
import { WorkingFor } from "../src/agent-session/acpmux/conversation/WorkingFor";
import { turnView, WORKING } from "../src/agent-session/acpmux/conversation/turns";
import { ToolRows } from "../src/agent-session/acpmux/conversation/TurnRows";
import {
  resetTranscriptDisclosure,
  TranscriptDisclosureProvider,
} from "../src/agent-session/acpmux/conversation/transcriptDisclosure";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
// A command call; two in a row group under "Running 2 commands", one alone is its own row.
const call = (id: string, status: string) => ({
  kind: "tool",
  text: "",
  tool: { id, title: id, kind: "execute", status, command: id },
});
type Call = {
  kind: string;
  text: string;
  tool: { id: string; title: string; kind: string; status: string };
};

const liveTurn = (calls: Call[]) =>
  turnView(
    [row("u", "user"), row("a", "assistant", { text: "On it." }), row("run", "activity", { items: calls })],
    new Set(),
    { working: true },
  );
function statusLine(calls: Call[]): AcpmuxRow {
  const status = liveTurn(calls).find((entry) => entry.kind === WORKING);
  if (!status) throw new Error("no status line");
  return status;
}

const drawn = (status: AcpmuxRow) => renderToStaticMarkup(<WorkingFor row={status} now={() => status.at + 26_000} />);
// The line draws nothing before its words: no working mark, no activity dots, and its first child
// is the label itself.
const stillMarkup = (html: string) =>
  /^<div[^>]*>(?:<span class="cv-shimmer__row">)?<(?:span|output) class="cv-(?:worked__label|thinking|activity__label)/.test(
    html,
  ) && !/cv-working-mark|cv-activity__dots/.test(html);
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

/// The running turn as the transcript draws it: the line over the run's tool rows, in one session.
function Turn({ rows }: { rows: AcpmuxRow[] }) {
  return (
    <TranscriptDisclosureProvider sessionId="s">
      {rows.map((entry) =>
        entry.kind === WORKING ? (
          <WorkingFor key={entry.id} row={entry} now={() => entry.at + 26_000} />
        ) : entry.kind === "activity" ? (
          <ToolRows key={entry.id} row={entry} sessionId="s" />
        ) : null,
      )}
    </TranscriptDisclosureProvider>
  );
}

/// Mounts the turn in a DOM, so a click on a group's line closes it, and hands `use` the page.
function mounted(calls: Call[], use: (page: HTMLElement) => void) {
  const scope = globalThis as Record<string, unknown>;
  const keys = ["window", "document", "localStorage", "IS_REACT_ACT_ENVIRONMENT"];
  const saved = keys.map((key) => [key, scope[key]] as const);
  const dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  resetTranscriptDisclosure();
  const page = dom.window.document.getElementById("root")!;
  const root = createRoot(page);
  try {
    act(() => root.render(<Turn rows={liveTurn(calls)} />));
    use(page);
  } finally {
    act(() => root.unmount());
    resetTranscriptDisclosure();
    dom.window.close();
    for (const [key, value] of saved) {
      if (value === undefined) delete scope[key];
      else scope[key] = value;
    }
  }
}
const line = (page: HTMLElement) => page.querySelector(".cv-worked")!;
const closeGroup = (page: HTMLElement) =>
  act(() => page.querySelector<HTMLButtonElement>("button.cv-tool[aria-expanded]")!.click());
/// The line while the reader has the running call's group closed, so no row of its own names it.
function closedLine(calls: Call[]): string {
  let html = "";
  mounted(calls, (page) => {
    closeGroup(page);
    html = line(page).outerHTML;
  });
  return html;
}

test("while a call runs, the status line names it beside the turn's time", () => {
  const calls = [call("git log", "completed"), call("bun test", "in_progress")];
  expect(statusLine(calls).doing).toBe("bun test");
  const html = closedLine(calls);
  expect(text(html)).toBe("bun test 26s");
  // A command leads with the terminal glyph, still; nothing blinks.
  expect(html).toContain("cv-worked__glyph");
  expect(html).not.toMatch(/cv-working-mark|cv-activity__dots/);
});

// Lawrence (2026-10-20): a running command's line read as a cropped terminal thumbnail. It leads
// with the terminal glyph the tool rows use, as Claude desktop's line does; other calls lead with
// their label alone.
test("a command in flight leads with the terminal glyph", () => {
  const calls = [call("git status", "completed"), call("cd ~/Projects/cmux && git log", "in_progress")];
  expect(statusLine(calls).doingCommand).toBe(true);
  expect(closedLine(calls)).toContain("cv-worked__glyph");
});

const read = (id: string, title: string, extra: Record<string, string> = {}) => ({
  kind: "tool",
  text: "",
  tool: { id, title, kind: "read", status: "in_progress", ...extra },
});

test("any other call in flight leads with its label alone", () => {
  const calls = [read("p", "Read package.json"), read("r", "Read app.ts")];
  expect(statusLine(calls).doingCommand).toBeUndefined();
  const html = closedLine(calls);
  expect(text(html)).toBe("Read app.ts 26s");
  expect(html).not.toContain("cv-worked__glyph");
  expect(stillMarkup(html)).toBe(true);
});

test("between calls, the line reads Working for, with no mark before it", () => {
  const status = statusLine([call("git log", "completed")]);
  expect(status.doing).toBeUndefined();
  const html = drawn(status);
  expect(text(html)).toBe("Working for 26s");
  expect(stillMarkup(html)).toBe(true);
});

test("Thinking is the word alone, with no mark before it; the word itself shimmers", () => {
  const html = renderToStaticMarkup(<Thinking />);
  expect(text(html)).toBe("Thinking");
  expect(stillMarkup(html)).toBe(true);
  expect(html).toContain('class="cv-thinking is-shimmer"');
});

test("a running label's shimmer includes its timer and uses the slow cadence", async () => {
  const html = renderToStaticMarkup(
    <Thinking
      since={at}
      doing="Read the Freestyle lanes note; check dispatcher"
      doingAt={at}
      now={() => at + 50_000}
    />,
  );
  expect(html).toContain('class="cv-shimmer__row"');
  expect(html).toContain('class="cv-shimmer__lit-time" data-text="50s"');
  const css = await Bun.file(new URL("../src/pages/shared/desktop.css", import.meta.url)).text();
  expect(css).toContain("--cmux-shimmer-period: 2.8s");
  expect(css).toMatch(/@keyframes cmux-shimmer-band[\s\S]*?45%[\s\S]*?100%/);
});

test("the line while the agent starts is Thinking, with no Cancel", () => {
  const html = renderToStaticMarkup(<Thinking starting />);
  expect(html).toContain("is-shimmer");
  expect(html).not.toContain(translate("switch.cancelPrompt"));
});

test("the activity line names the work with no dots before it", () => {
  const html = renderToStaticMarkup(
    <ActivityLine row={row("act", "activity-line", { text: "Edit grid.css" })} now={() => at + 26_000} />,
  );
  expect(text(html)).toMatch(/^Edit grid\.css \d+s$/);
  expect(stillMarkup(html)).toBe(true);
});

test("live activity lines share the page's one second and rest while the page is hidden", () => {
  const scope = globalThis as Record<string, unknown>;
  const keys = ["window", "document", "IS_REACT_ACT_ENVIRONMENT", "setInterval"];
  const saved = keys.map((key) => [key, scope[key]] as const);
  const dom = new JSDOM("<!doctype html><main id=root></main>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  let visibility = "visible";
  Object.defineProperty(dom.window.document, "visibilityState", {
    configurable: true,
    get: () => visibility,
  });
  let intervals = 0;
  const realInterval = globalThis.setInterval;
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    IS_REACT_ACT_ENVIRONMENT: true,
    setInterval: ((handler: () => void, ms?: number) => {
      intervals += 1;
      return realInterval(handler, ms);
    }) as unknown as typeof setInterval,
  });
  const root = createRoot(dom.window.document.getElementById("root")!);
  const lines = Array.from({ length: 5 }, (_, index) =>
    row(`act-${index}`, "activity-line", { text: `Edit grid-${index}.css` }),
  );
  try {
    act(() => root.render(lines.map((line) => <ActivityLine key={line.id} row={line} now={() => at + 26_000} />)));
    expect(dom.window.document.querySelectorAll(".cv-activity__time")).toHaveLength(5);
    // Five live lines, one timer: none of their own, and the page clock's one for all of them.
    expect(intervals).toBe(0);
    expect(pageClocks(dom.window.document)).toMatchObject({ running: 1, subscribers: 5 });
    act(() => {
      visibility = "hidden";
      dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
    });
    expect(pageClocks(dom.window.document)).toMatchObject({ running: 0, subscribers: 5 });
  } finally {
    act(() => root.unmount());
    dom.window.close();
    for (const [key, value] of saved) {
      if (value === undefined) delete scope[key];
      else scope[key] = value;
    }
  }
  expect(pageClocks(dom.window.document)).toEqual({ running: 0, subscribers: 0, items: [] });
});

test("a call whose title is its raw input reads as a label, not JSON", () => {
  const raw = '{"file_path":"src/app.ts"}';
  const status = statusLine([read("p", "Read package.json"), read("r", raw, { inputSummary: raw })]);
  expect(status.doing).toContain("app.ts");
  expect(status.doing).not.toContain("{");
});

test("no dots loop on the running line; only the word Thinking shimmers, in the theme accent", async () => {
  const css = await Bun.file(
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
  ).text();
  expect(css).not.toContain("cv-thinking-sweep");
  expect(css).not.toMatch(/cv-working-mark|cv-working-dot|cv-activity__dots|cv-activity-dot/);
  // The sweep runs only with motion allowed and the status look not static, on the shared clock's
  // keyframes (two transform loops, ShimmerText.tsx), its lit words mixed from the theme accent
  // (never a literal color). working-loops-compositor.test.tsx checks the loops in the engines.
  const rule = (selector: string) =>
    css.match(new RegExp(`:root:not\\(\\[data-status-indicators="static"\\]\\) \\${selector} \\{([^}]*)\\}`));
  const band = rule(".cv-shimmer__band");
  const lit = rule(".cv-shimmer__lit");
  expect(band![1]).toContain("animation: cmux-shimmer-band");
  expect(lit![1]).toContain("animation: cmux-shimmer-lit");
  expect(lit![1]).toContain("var(--agent-accent");
  expect(lit![1]).not.toMatch(/#[0-9a-f]{3,8}\b|rgb\(|orange/i);
});

// Find counts and visits only transcript rows (findMatches skips the working row), so the status
// line must not be painted either, or searching the running command highlights a match the count
// never reaches (chatFind.ts paintFindHighlights skips [data-find-skip]).
test("Find skips the status line: it is not a match the count can reach", () => {
  const skipped = (html: string) => /^<div class="cv-worked[^"]*" data-find-skip="/.test(html);
  expect(skipped(drawn(statusLine([call("bun test", "in_progress")])))).toBe(true);
  expect(skipped(drawn(statusLine([call("git log", "completed")])))).toBe(true);
  expect(skipped(renderToStaticMarkup(<Thinking />))).toBe(true);
});

// One running call reads once (Leo, 2026-10-21): its own tool row, right under the line, already
// names it, so while that row is on screen the line says "Working for 26s" alone, with no glyph.
const times = (html: string, words: string) => text(html).split(words).length - 1;

test("one running call reads once: its own tool row names it, the line does not", () => {
  const html = renderToStaticMarkup(<Turn rows={liveTurn([call("bun test", "in_progress")])} />);
  expect(times(html, "bun test")).toBe(1);
  expect(text(html)).toContain("Working for 26s");
  expect(html).not.toContain("cv-worked__glyph");
});

test("a running call whose group the reader closed is named on the line again", () => {
  mounted([call("git log", "completed"), call("bun test", "in_progress")], (page) => {
    // The group of commands opens by default, so the running call's row is on screen.
    expect(times(page.innerHTML, "bun test")).toBe(1);
    expect(line(page).textContent).toBe("Working for 26s");
    closeGroup(page);
    expect(line(page).textContent).toBe("bun test26s");
    expect(line(page).querySelector(".cv-worked__glyph")).not.toBeNull();
  });
});
