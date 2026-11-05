// l10n-allow-file: test fixtures.
// A tool's notice in the transcript (IncomingMessageCard.tsx, agentNotice.ts): one received line,
// the severity's mark in the icon column, the sender and its machine, the title as the line; opened,
// the body and its links named as chips would name them, never the rendered head or the Links line.
// Several in a row fold under "Received N notices", whose head shows a fire when one is in it.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { IncomingMessageLine } from "./IncomingMessageCard";
import { LaneNoticeBatch } from "./LaneNoticeBatch";
import { incomingPrompt, type IncomingMessage } from "./incomingMessage";
import { projectInboxRows } from "./laneNoticeBatches";
import { LANE_NOTICE_BATCH, type AcpmuxRow } from "../model";
import { findSkipped } from "./chatFind";
import { isVisiblyEmptyMessage } from "./visibleMessage";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

const PR = "https://github.com/manaflow-ai/cmux/pull/32827";
const RUN = "https://github.com/manaflow-ai/cmux/actions/runs/19022341987";

function notice(
  severity: "info" | "warn" | "fire",
  title: string,
  body = "Failed steps: Run the fast tier.",
): IncomingMessage {
  const tag = severity === "info" ? "" : ` · ${severity.toUpperCase()}`;
  const raw = `[notice from base-red-watch on ci-mini-3${tag}] ${title}\n${body}\nLinks: ${PR} (#32827), ${RUN}`;
  const provenance = {
    kind: "notice",
    from: "fromAgent",
    fromName: "base-red-watch",
    to: "s-1",
    notice: { sender: "base-red-watch", host: "ci-mini-3", severity, title, links: [{ url: PR }, { url: RUN }] },
  };
  const read = incomingPrompt(raw, { _meta: { provenance } });
  if (read?.kind !== "message") throw new Error("not a message");
  return read.message;
}

test("a fire notice is one line: its red mark, the sender and machine, the title; opened, the body and links", async () => {
  const container = await render(
    <IncomingMessageLine
      id="n-1"
      message={notice("fire", "cmux-next fast tier failed on 3 PRs")}
      onOpen={() => undefined}
    />,
  );
  const line = container.querySelector(".cv-received.cv-notice")!;
  expect(line.classList.contains("is-fire")).toBe(true);
  expect(line.querySelector(".cv-received__mark .cv-notice-mark")?.getAttribute("data-severity")).toBe("fire");
  expect(line.querySelector(".cv-received__from")?.textContent).toBe("base-red-watch");
  expect(line.querySelector(".cv-received__host")?.textContent).toBe("ci-mini-3");
  expect(line.querySelector(".cv-notice__title")?.textContent).toBe("cmux-next fast tier failed on 3 PRs");
  // Find reaches the title on its line (the rest of the line is a summary Find skips).
  const title = line.querySelector(".cv-notice__title")!;
  expect(findSkipped(title.firstChild?.parentElement ?? title)).toBe(false);
  expect(findSkipped(line.querySelector(".cv-received__host"))).toBe(true);
  // Nothing in the mark moves: no animation on the page's mark.
  expect(container.innerHTML).not.toContain("animate");
  await act(async () => (line.querySelector(".cv-disclosure__toggle") as HTMLElement).click());
  const text = container.querySelector(".cv-received__text")!;
  expect(text.textContent).toContain("Failed steps: Run the fast tier.");
  expect(text.textContent).not.toContain("[notice from");
  expect(text.textContent).not.toContain("Links:");
  const links = [...text.querySelectorAll("a")].map((a) => a.getAttribute("href"));
  expect(links).toContain(PR);
  expect(links).toContain(RUN);
  expect(text.textContent).toContain("run 1902234…");
});

test("a fold of notices reads Received N notices and shows the fire on its head", async () => {
  const row = (id: string, message: IncomingMessage): AcpmuxRow =>
    ({
      id,
      version: 1,
      at: 1,
      kind: "user",
      text: message.text,
      untyped: true,
      incoming: { kind: "message", message },
    }) as AcpmuxRow;
  const rows = projectInboxRows([
    row("a", notice("info", "Landed #32790")),
    row("b", notice("fire", "fast tier failed")),
    row("c", notice("warn", "queue is 40 min deep")),
  ]);
  expect(rows.length).toBe(1);
  expect(rows[0]!.kind).toBe(LANE_NOTICE_BATCH);
  const container = await render(<LaneNoticeBatch row={rows[0]!} renderMessage={() => null} />);
  const head = container.querySelector(".cv-message-group__head")!;
  expect(head.querySelector(".cv-message-group__count")?.textContent).toBe("Received 3 notices");
  expect(head.querySelector(".cv-notice-mark")?.getAttribute("data-severity")).toBe("fire");
});

test("a notice of a title alone is still a row", () => {
  const message = notice("fire", "fast tier failed", "");
  expect(message.text).toBe("");
  const row = {
    id: "t",
    version: 1,
    at: 1,
    kind: "user",
    text: "fast tier failed",
    incoming: { kind: "message", message },
  } as AcpmuxRow;
  expect(isVisiblyEmptyMessage(row)).toBe(false);
});

test("acpmux's own who-else notice (kind who_else) reads as a notice, not the person's prompt", () => {
  const title = "greet-codex also edits greeting.txt";
  const raw = `[notice from acpmux who-else] ${title}\nMessage it with acpmux send greet-codex.`;
  const provenance = {
    kind: "who_else",
    from: "fromAgent",
    fromName: "acpmux who-else",
    to: "s-1",
    notice: { sender: "acpmux who-else", severity: "info", title, links: [] },
  };
  const read = incomingPrompt(raw, { _meta: { provenance } });
  if (read?.kind !== "message") throw new Error("not a message");
  expect(read.message.notice?.title).toBe(title);
  expect(read.message.name).toBe("acpmux who-else");
});
