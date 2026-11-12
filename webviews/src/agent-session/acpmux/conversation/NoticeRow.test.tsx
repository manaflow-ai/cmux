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
import { incomingPrompt, messagePreview, type IncomingMessage } from "./incomingMessage";
import { projectInboxRows } from "./laneNoticeBatches";
import { LANE_NOTICE_BATCH, type AcpmuxRow } from "../model";
import { findSkipped } from "./chatFind";
import { isVisiblyEmptyMessage } from "./visibleMessage";
import { settleReact } from "../../../../test/support/domTeardown";

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
  await settleReact();
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

// acpmux's own end of a background command (hub/bg_notify.rs): sender `acpmux`, severity from the
// exit status alone (`info` for exit 0, `warn` for any other end), title `Background command
// finished: COMMAND (exit N)` with the command cut to 120 characters. Leo, 2026-11-08: "why was
// there a yellow warning symbol? ... why is there only ACPMux as a bare thing".
function bgEnd(task: string, command: string, exit: number, output: string) {
  const severity = exit === 0 ? "info" : "warn";
  const title = `Background command finished: ${command} (exit ${exit})`;
  const notice = { sender: "acpmux", severity, title };
  const text = `[notice from acpmux${exit === 0 ? "" : " · WARN"}] ${title}\nTask ${task}: ${command}\nLast 3 lines of its output:\n${output}\n(bg_output reads all of it.)`;
  const provenance = { kind: "notice", from: "fromAgent", fromName: "acpmux", to: "s-1", notice, bgTaskId: task };
  return { text, provenance };
}
const LONG = `wt new manaflow-ai/cmux lane/summary-sources-screenshot-labels --topic 'summary card Sources screenshot labels' --files…`;
const REMOTE =
  "remote:\nremote: Create a pull request for 'fast-checks/5023' on GitHub by visiting:\nwarning: redirecting to https://github.com/x";

test("a command that exited 0 reads as info whatever its output looks like, and its line keeps the exit", async () => {
  const end = bgEnd("bg-1", "cmux-ci test --committed -- 'cd tools && python3 -m unittest'", 0, REMOTE);
  const read = incomingPrompt(end.text, { _meta: { provenance: end.provenance } });
  if (read?.kind !== "message") throw new Error("not a message");
  expect(read.message.notice?.severity).toBe("info");
  const container = await render(<IncomingMessageLine id="n-1" message={read.message} onOpen={() => undefined} />);
  const line = container.querySelector(".cv-received.cv-notice")!;
  expect(line.querySelector(".cv-notice-mark")?.getAttribute("data-severity")).toBe("info");
  // The outcome is its own slot that never shrinks, so a long command never cuts it off.
  expect(line.querySelector(".cv-notice__end")?.textContent?.trim()).toBe("(exit 0)");
  expect(line.querySelector(".cv-notice__lead")?.textContent).toBe(
    "Background command finished: cmux-ci test --committed -- 'cd tools && python3 -m unittest'",
  );
});

test("a failed command's warning shows its exit on the line", async () => {
  const end = bgEnd("bg-2", LONG, 2, REMOTE);
  const read = incomingPrompt(end.text, { _meta: { provenance: end.provenance } });
  if (read?.kind !== "message") throw new Error("not a message");
  const container = await render(<IncomingMessageLine id="n-2" message={read.message} onOpen={() => undefined} />);
  const line = container.querySelector(".cv-received.cv-notice")!;
  expect(line.querySelector(".cv-notice-mark")?.getAttribute("data-severity")).toBe("warn");
  expect(line.querySelector(".cv-notice__end")?.textContent?.trim()).toBe("(exit 2)");
});

// User, 2026-11-09: "generally in gui we should not mention stuff like \"acpmux\"". A background
// command's end names cmux as its sender, and its opened body never shows the task's internal id or
// the tool the model reads it with.
test("a background command's notice never shows acpmux, its task id or bg_output", async () => {
  const end = bgEnd("bg-b08e9de42d3e", "make test", 0, "lint: ok\ntest: 412 passed\nOK");
  const read = incomingPrompt(end.text, { _meta: { provenance: end.provenance } });
  if (read?.kind !== "message") throw new Error("not a message");
  expect(read.message.name).toBe("cmux");
  const container = await render(<IncomingMessageLine id="n-9" message={read.message} onOpen={() => undefined} />);
  const line = container.querySelector(".cv-received.cv-notice")!;
  expect(line.textContent).toContain("cmux");
  expect(line.textContent).not.toMatch(/acpmux/i);
  await act(async () => (line.querySelector(".cv-disclosure__toggle") as HTMLElement).click());
  const all = container.textContent ?? "";
  expect(all).toContain("test: 412 passed");
  expect(all).not.toMatch(/acpmux|bg-b08e9de42d3e|bg_output/i);
  for (const el of container.querySelectorAll("[aria-label],[title]"))
    expect(`${el.getAttribute("aria-label") ?? ""} ${el.getAttribute("title") ?? ""}`).not.toMatch(/acpmux/i);
});

/// Notices that waited behind a busy turn go in as one (acpmux hub/digest.rs `digest_blocks`).
function digest(...ends: { text: string; provenance: Record<string, unknown> }[]) {
  const parts = ends.map(
    (end, i) => `${i ? "\n\n" : ""}[agent message ${i + 1} of ${ends.length}] from acpmux\n${end.text}`,
  );
  const text = `${ends.length} messages from other agents arrived while you were busy. Each follows as it was sent, oldest first.\n\n${parts.join("")}`;
  const messages = ends.map((end, i) => ({ promptId: `bg-done-${i}`, from: "acpmux", provenance: end.provenance }));
  return incomingPrompt(text, { _meta: { provenance: { kind: "agent_digest", messages } } });
}

test("background command ends that went in together read as their notice, never acpmux twice", async () => {
  const read = digest(bgEnd("bg-3", LONG, 0, "note: one"), bgEnd("bg-4", "cargo fmt --check", 0, "ok"));
  if (read?.kind !== "message") throw new Error("not a message");
  expect(read.message.name).toBe("cmux");
  expect(read.message.notice?.title).toBe(`Background command finished: ${LONG} (exit 0)`);
  expect(read.message.notice?.more).toBe(1);
  const container = await render(<IncomingMessageLine id="n-3" message={read.message} onOpen={() => undefined} />);
  const line = container.querySelector(".cv-received.cv-notice")!;
  expect(line.querySelector(".cv-notice-mark")?.getAttribute("data-severity")).toBe("info");
  expect(line.querySelector(".cv-notice__end")?.textContent?.trim()).toBe("(exit 0)");
  expect(line.querySelector(".cv-notice__title")?.textContent).not.toBe("acpmux");
  await act(async () => (line.querySelector(".cv-disclosure__toggle") as HTMLElement).click());
  const text = container.querySelector(".cv-received__text")!.textContent ?? "";
  // Opened: each notice's own title, then its body, never the rendered head.
  expect(text).toContain("Background command finished: cargo fmt --check (exit 0)");
  expect(text).not.toContain("Task bg-4");
  expect(text).not.toContain("[notice from");
});

test("one notice that went in as a digest reads as that notice", () => {
  const read = digest(bgEnd("bg-5", "make", 3, "boom"));
  if (read?.kind !== "message") throw new Error("not a message");
  expect(read.message.notice).toMatchObject({ severity: "warn", title: "Background command finished: make (exit 3)" });
  expect(read.message.notice?.more).toBeUndefined();
  expect(read.message.text.startsWith("Last 3 lines of its output:")).toBe(true);
});

test("the most severe notice of a digest names its line", () => {
  const read = digest(bgEnd("bg-6", "ls", 0, "a"), bgEnd("bg-7", "make", 2, "b"), bgEnd("bg-8", "pwd", 0, "c"));
  if (read?.kind !== "message") throw new Error("not a message");
  expect(read.message.notice).toMatchObject({
    severity: "warn",
    title: "Background command finished: make (exit 2)",
    more: 2,
  });
});

test("a digest of a notice and an agent's message shows the first message's words, not its sender's name", () => {
  const end = bgEnd("bg-9", LONG, 0, "x");
  const text = `2 messages from other agents arrived while you were busy. Each follows as it was sent, oldest first.\n\n[agent message 1 of 2] from acpmux\n${end.text}\n\n[agent message 2 of 2] from lane-a\nShipped the fix.`;
  const messages = [
    { promptId: "bg-done-9", from: "acpmux", provenance: end.provenance },
    { promptId: "p2", from: "lane-a" },
  ];
  const read = incomingPrompt(text, { _meta: { provenance: { kind: "agent_digest", messages } } });
  if (read?.kind !== "message") throw new Error("not a message");
  expect(read.message.name).toBe("acpmux, lane-a");
  expect(read.message.preview).toBe(`Background command finished: ${LONG} (exit 0)`);
  expect(messagePreview(read.message.text)).not.toBe(`Background command finished: ${LONG} (exit 0)`);
  expect(read.message.text).not.toContain("[notice from");
});

test("a notice whose title is longer than a line allows still reads as a notice, its title cut", () => {
  const end = bgEnd("bg-10", "x".repeat(260), 0, "y");
  const read = incomingPrompt(end.text, { _meta: { provenance: end.provenance } });
  if (read?.kind !== "message") throw new Error("not a message");
  expect(read.message.notice?.severity).toBe("info");
  expect(read.message.notice?.title.length).toBeLessThanOrEqual(200);
  expect(read.message.notice?.title.endsWith("(exit 0)")).toBe(true);
  expect(read.message.text).not.toContain("[notice from");
});

// Review follow-ups on #38226 (F1-F3).
test("each notice of a digest keeps its own links, a fire's after many others' too", () => {
  const PR_LINK = (n: number) => ({ url: `https://github.com/manaflow-ai/cmux/pull/${n}` });
  const info = (i: number) => ({
    text: `[notice from lander] Landed #${i}\nok`,
    provenance: {
      kind: "notice",
      from: "fromAgent",
      fromName: "lander",
      notice: { sender: "lander", severity: "info", title: `Landed #${i}`, links: [PR_LINK(i)] },
    },
  });
  const ends = Array.from({ length: 17 }, (_, i) => info(i + 1));
  ends.push({
    text: "[notice from watch · FIRE] fast tier red\nlook",
    provenance: {
      kind: "notice",
      from: "fromAgent",
      fromName: "watch",
      notice: { sender: "watch", severity: "fire", title: "fast tier red", links: [PR_LINK(99999)] },
    },
  });
  const read = digest(...ends);
  if (read?.kind !== "message") throw new Error("not a message");
  expect(read.message.notice?.severity).toBe("fire");
  expect(read.message.text).toContain("pull/99999");
  expect(read.message.text).toContain("pull/1)");
});

test("a rendered notice sent at a shell keeps its severity inside a digest", () => {
  const text =
    "1 messages from other agents arrived while you were busy. Each follows as it was sent, oldest first.\n\n[agent message 1 of 1] from base-red-watch\n[notice from base-red-watch on ci-mini-3 · FIRE] fast tier failed\nboom";
  const messages = [{ promptId: "p", from: "base-red-watch" }];
  const read = incomingPrompt(text, { _meta: { provenance: { kind: "agent_digest", messages } } });
  if (read?.kind !== "message") throw new Error("not a message");
  expect(read.message.notice).toMatchObject({ severity: "fire", title: "fast tier failed", host: "ci-mini-3" });
  expect(read.message.text).toBe("boom");
});

test("Find matches across a notice title's command and its exit", async () => {
  const end = bgEnd("bg-11", "make", 0, "ok");
  const read = incomingPrompt(end.text, { _meta: { provenance: end.provenance } });
  if (read?.kind !== "message") throw new Error("not a message");
  const container = await render(<IncomingMessageLine id="n-11" message={read.message} onOpen={() => undefined} />);
  const title = container.querySelector(".cv-notice__title")!;
  expect(title.hasAttribute("data-find-join")).toBe(true);
  expect(title.textContent).toBe("Background command finished: make (exit 0)");
});
