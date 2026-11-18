import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { noChat, summary, user } from "../src/gallery/fixtures/acpmux";
import { canResumeFromComposer } from "../src/agent-session/acpmux/composer/resumeControl";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;
let handle: ComposerHandle;
let chats = 0;
let stoppedCount = 0;
const sent: string[] = [];

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  for (const [key, value] of Object.entries({
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    KeyboardEvent: window.KeyboardEvent,
    MouseEvent: window.MouseEvent,
    InputEvent: window.InputEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    localStorage: window.localStorage,
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    IS_REACT_ACT_ENVIRONMENT: true,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  sent.length = 0;
  stoppedCount = 0;
});
afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
});

function stopped(): AcpmuxSnapshot {
  const sessionId = `composer-resume-${++chats}`;
  return noChat([], {
    sessionId,
    summary: { sessionId, harness: "codex", family: "codex", cwd: "/repo", turnCount: 1 },
    rows: [user("Review the changes.", 1), summary(0.9, { status: "interrupted", durationMs: 5_000 })],
  });
}
const emptyState = {
  offered: true,
  text: "",
  attachments: 0,
  pending: 0,
  shell: false,
  running: false,
  readOnly: false,
  blocked: false,
  dictating: false,
};

test("Resume requires an empty stopped-turn offer and cannot race work, queue, goal or composer input", () => {
  const snapshot = stopped();
  expect(canResumeFromComposer(snapshot, emptyState)).toBe(true);
  for (const change of [
    { offered: false },
    { text: "next" },
    { text: " " },
    { attachments: 1 },
    { pending: 1 },
    { shell: true },
    { running: true },
    { readOnly: true },
    { blocked: true },
    { dictating: true },
  ])
    expect(canResumeFromComposer(snapshot, { ...emptyState, ...change })).toBe(false);
  for (const changed of [
    { ...snapshot, isWorking: true },
    { ...snapshot, connection: "disconnected" },
    { ...snapshot, connection: "connecting…" },
    { ...snapshot, queue: [{ id: "queued", prompt: "Next" }] },
    { ...snapshot, summary: { ...snapshot.summary!, watching: "another-owner" } },
    { ...snapshot, summary: { ...snapshot.summary!, goal: { objective: "Finish", status: "active" as const } } },
    { ...snapshot, summary: { ...snapshot.summary!, goal: { objective: "Finish", status: "running" as const } } },
  ])
    expect(canResumeFromComposer(changed, emptyState)).toBe(false);
});

async function draw(snapshot: AcpmuxSnapshot, onResume?: () => Promise<void | boolean>) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={snapshot.sessionId}
        chips={() => null}
        handle={(value) => {
          if (value) handle = value;
        }}
        onResume={onResume}
        onSend={(text) => {
          sent.push(text);
          return true;
        }}
        onStop={() => {
          stoppedCount++;
        }}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[]}
      />,
    ),
  );
}
const resumeButton = () => host.querySelector<HTMLButtonElement>('button[aria-label="Resume"]');
const click = (button: HTMLButtonElement) => act(async () => button.click());

test("the empty composer exposes a play Resume control, then typing and attachments restore Send", async () => {
  const snapshot = stopped();
  await draw(snapshot, async () => true);
  expect(resumeButton()?.querySelector('[data-icon="media.play"]')).not.toBeNull();
  expect(resumeButton()?.type).toBe("button");
  await act(async () => handle.restore("A new prompt", []));
  expect(resumeButton()).toBeNull();
  expect(host.querySelector('button[aria-label="Send"]')).not.toBeNull();
  await act(async () => handle.take());
  expect(resumeButton()).not.toBeNull();
  await act(async () =>
    handle.restore("", [
      { id: "image", kind: "image", name: "frame.png", mimeType: "image/png", size: 1, data: "YQ==" },
    ]),
  );
  expect(resumeButton()).toBeNull();
  expect(host.querySelector('button[aria-label="Send"]')).not.toBeNull();
});

test("Resume is one-at-a-time and does not clear text added while it awaits the owner", async () => {
  let finish!: (value: boolean) => void;
  let resumed = 0;
  await draw(stopped(), () => {
    resumed++;
    return new Promise((resolve) => {
      finish = resolve;
    });
  });
  await click(resumeButton()!);
  expect(resumed).toBe(1);
  expect(resumeButton()?.disabled).toBe(true);
  await act(async () =>
    host.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })),
  );
  expect(resumed).toBe(1);
  await act(async () =>
    handle.restore("Keep this draft", [
      { id: "new-image", kind: "image", name: "new.png", mimeType: "image/png", size: 1, data: "YQ==" },
    ]),
  );
  expect(resumeButton()).toBeNull();
  await act(async () => finish(true));
  expect(handle.draft().text).toContain("Keep this draft");
  expect(handle.draft().attachments.map((attachment) => attachment.name)).toEqual(["new.png"]);
  expect(sent).toEqual([]);
});

test("clearing a draft during an outstanding Resume cannot activate a second Resume", async () => {
  let finish!: (value: boolean) => void;
  let resumed = 0;
  await draw(stopped(), () => {
    resumed++;
    return new Promise((resolve) => {
      finish = resolve;
    });
  });
  await click(resumeButton()!);
  await act(async () => handle.restore("Next", []));
  await act(async () => handle.take());
  expect(resumeButton()?.disabled).toBe(true);
  await click(resumeButton()!);
  expect(resumed).toBe(1);
  await act(async () => finish(true));
  expect(resumeButton()?.disabled).toBe(false);
});

test("plain Return in the empty composer resumes instead of sending a literal prompt", async () => {
  let resumed = 0;
  await draw(stopped(), async () => {
    resumed++;
    return true;
  });
  const field = host.querySelector<HTMLElement>('[role="combobox"]')!;
  await act(async () =>
    field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })),
  );
  expect(resumed).toBe(1);
  expect(sent).toEqual([]);
});

test("a refused Resume leaves the draft untouched and releases its busy state", async () => {
  await draw(stopped(), async () => false);
  await click(resumeButton()!);
  expect(resumeButton()?.disabled).toBe(false);
  expect(host.textContent).toContain("Couldn't resume this chat");
  expect(handle.draft().text).toBe("");
  expect(sent).toEqual([]);
});

test("the owner removing the stopped-turn offer removes Resume", async () => {
  const snapshot = stopped();
  await draw(snapshot, async () => true);
  expect(resumeButton()).not.toBeNull();
  await draw(snapshot);
  expect(resumeButton()).toBeNull();
});

test("stopped footer keeps a subdued duration label and no footer Continue control", async () => {
  const { createRoot } = await import("react-dom/client");
  const { WorkedFor, TurnFooter } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
  root = createRoot(host);
  const row = summary(0.9, { status: "interrupted", durationMs: 5_000, resumable: true });
  await act(async () =>
    root!.render(
      <TurnActionsContext.Provider value={{ resume: async () => {} }}>
        <WorkedFor row={row} expanded onToggle={() => {}} />
        <TurnFooter row={row} />
      </TurnActionsContext.Provider>,
    ),
  );
  expect(host.querySelector(".cv-worked")?.textContent).toContain("You stopped after 5s");
  const { workedLabel } = await import("../src/agent-session/acpmux/conversation/turns");
  const { translatorFor } = await import("../src/agent-session/acpmux/i18n");
  expect(workedLabel(translatorFor("en"), row)).toContain("You stopped after 5s");
  expect(host.querySelector(".cv-turn-continue")).toBeNull();
});

test("a rapid second click after Resume becomes Stop cannot cancel the resumed turn", async () => {
  const snapshot = stopped();
  let finish!: (value: boolean) => void;
  await draw(
    snapshot,
    () =>
      new Promise((resolve) => {
        finish = resolve;
      }),
  );
  await click(resumeButton()!);
  await draw({ ...snapshot, isWorking: true });
  const stop = host.querySelector<HTMLButtonElement>('button[aria-label="Stop"]')!;
  expect(stop).not.toBeNull();
  await click(stop);
  expect(stoppedCount).toBe(0);
  await act(async () => finish(true));
});
