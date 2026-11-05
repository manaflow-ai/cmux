// The person's Stop ends the turn and keeps the queue (acpmux hub/cancel.rs): their queued prompts
// stay, held by the Stop, and the next one waits for them to send it. The tray says so in one quiet
// line with the queue's Resume, never a failed turn's error (the UI ceremony audit's lens review,
// 2026-11-05: the person stays in control of what is sent).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translatorFor } from "../src/agent-session/acpmux/i18n";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "ResizeObserver", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM(
    "<!doctype html><div class=acpmux-main><div class=acpmux-composer-box id=root></div></div>",
  );
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    ResizeObserver: (window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const held = [
  { id: "q1", prompt: "Also update the comment above the retry loop", heldByStop: true },
  { id: "q2", prompt: "Then run the tests", heldByStop: true },
];
const edits: [string, unknown][] = [];

async function draw(reason?: string) {
  const { createRoot } = await import("react-dom/client");
  const { ComposerQueue } = await import("../src/agent-session/acpmux/ComposerQueue");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <ComposerQueue
        queue={held as never}
        paused
        {...(reason ? { pauseReason: reason } : {})}
        t={translatorFor("en")}
        onRemove={async () => true}
        onChange={async (id, edit) => {
          edits.push([id, edit]);
          return true;
        }}
      />,
    ),
  );
}

test("after the person's Stop the queue says its prompts wait to be sent, with one Resume", async () => {
  // An earlier failure's error is not why this queue waits.
  await draw("429 rate limited");
  const note = host.querySelector(".acpmux-queue-paused");
  expect(note?.textContent).toContain("Stopped. These wait for you to send them");
  expect(note?.textContent).not.toContain("429");
  expect(host.querySelectorAll(".acpmux-queue-resume").length).toBe(1);
  // Both prompts stay in the queue: the Stop removed none.
  expect(host.querySelectorAll(".acpmux-queued").length).toBe(2);
  expect(edits).toEqual([]);
});

test("Resume sends the queue the Stop held, from its first prompt", async () => {
  await draw();
  const resume = host.querySelector<HTMLButtonElement>(".acpmux-queue-resume")!;
  await act(async () => resume.click());
  expect(edits).toEqual([["q1", { op: "resume" }]]);
});
