// Leo, 2026-11-09: "And also, I can't click into the composer at all to, like potentially type other
// stuff while it's doing that initial load situation." A Cloud start made the composer `inert` until it
// ended (#28686), because this tab closes when the chat opens on its machine and anything typed
// meanwhile went with it. Now the composer stays open: the sent prompt leaves it (it shows as the
// message, with the start under it), what is typed or pasted meanwhile is kept and lands in the started
// chat's composer as a draft (never sent), a failed start puts the prompt back in front of it, and a
// second Send while the start is out starts nothing.
//
// The pane runs its real client against the in-page mock daemon; the native host is a stub whose
// `cloud.startChat` (and `cloud.signIn`) answers when the test says. The host keeps what the sending
// page types meanwhile as the tab's unsent text (`chat.unsentDraft`, AgentUnsentDrafts) and seeds the
// started chat's page with it as its draft (CloudStartChat `openUploaded`): a started chat's page is
// a second mount whose handshake carries that seed. Nothing goes through the page's own storage: a
// pane on WebKit has a data store of its own (PageWebView+Pooled `.nonPersistent()`).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    location: dom.window.location,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    Element: dom.window.Element,
    Event: dom.window.Event,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    IntersectionObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key))
      replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  Object.assign(dom.window, { matchMedia: replacements.matchMedia });
  // jsdom lays nothing out and its Range has no rects: ProseMirror measures one to scroll.
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  Object.assign(dom.window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  host = dom.window.document.getElementById("root")!;
});

type Answer = (method: string, params: Record<string, unknown>) => Promise<unknown>;
let restoreAnswer: (() => void) | undefined;

/// The project folder is trusted on the mock daemon: no trust question holds the first send.
async function trustFolder() {
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  const proto = MockAcpmuxSocket.prototype as unknown as { answer: Answer };
  const answer = proto.answer;
  restoreAnswer = () => (proto.answer = answer);
  proto.answer = function (this: unknown, method, params) {
    if (method === "acp.trust.get" && params.cwd === FOLDER)
      return Promise.resolve({ cwd: FOLDER, level: "trusted", harnesses: { claude: "trusted", codex: "trusted" } });
    return answer.call(this, method, params);
  };
}

afterEach(async () => {
  restoreAnswer?.();
  restoreAnswer = undefined;
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(async () => {
  (await import("../src/agent-session/acpmux/newtab/chatStore")).markMockPage(false);
  await settleReact();
  dom.window.close();
  for (const [key, entry] of saved) {
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
  }
});

const tick = () =>
  act(async () => {
    await new Promise((done) => setTimeout(done, 0));
  });
async function until(check: () => boolean, what: string, within = 15_000) {
  const deadline = Date.now() + within;
  while (!check() && Date.now() < deadline) await tick();
  expect(check(), what).toBe(true);
}

type FieldElement = HTMLElement & {
  acpmuxMarkdownField?: {
    value(): string;
    type(text: string): unknown;
    focus(): void;
    insertTyped(text: string): void;
  };
};
const promptElement = () => host.querySelector<FieldElement>(".acpmux-composer-prompt");
const promptField = () => {
  const element = promptElement();
  return element?.querySelector("[contenteditable]") ? element.acpmuxMarkdownField : undefined;
};
const composerText = () => promptField()?.value() ?? "";
const composerBox = () => host.querySelector<HTMLElement>(".acpmux-composer-box");

type Debug = {
  runMode(mode?: string): { runMode?: string | null; error?: string };
  composeSend(text: string): Promise<{ sent?: boolean; error?: string }>;
};
const debug = () => (dom.window as unknown as { cmuxAcpmuxDebug?: Debug }).cmuxAcpmuxDebug!;
const actions = () => (dom.window as unknown as { cmuxAcpmuxActions?: Record<string, unknown> }).cmuxAcpmuxActions;

const FOLDER = "/tmp/cloud-project";
const PROMPT = "Run the sidebar tests and fix what fails";
const TYPED = "also check the nightly once that is done";

/// A new chat on the mock daemon whose host offers Cloud. `cloud.startChat` and `cloud.signIn` wait
/// until `answer` or `fail`; `ready` adds the handshake fields a started chat's page gets (its seed).
async function mount(ready: Record<string, unknown> = {}) {
  if (!restoreAnswer) await trustFolder();
  const starts: Record<string, unknown>[] = [];
  const posts: { method: string; params: Record<string, unknown> }[] = [];
  let settle: ((reply: unknown) => void) | undefined;
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string; params?: Record<string, unknown> }) => {
            posts.push({ method: message.method, params: message.params ?? {} });
            if (message.method === "cloud.startChat" || message.method === "cloud.signIn") {
              starts.push({ ...message.params, method: message.method });
              return new Promise((done) => (settle = done));
            }
            return Promise.resolve({
              ok: true,
              value:
                message.method === "ready"
                  ? {
                      protocolVersion: 1,
                      transport: "mock",
                      newSession: true,
                      machineName: "Mac",
                      sandboxState: true,
                      cwd: FOLDER,
                      ...ready,
                    }
                  : message.method === "sandbox.state"
                    ? {}
                    : message.method === "transport.gesture"
                      ? { ticket: "ticket-1" }
                      : undefined,
            });
          },
        },
      },
    },
  });
  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  root = createRoot(host);
  await act(async () => root!.render(<AcpmuxApp />));
  await until(() => actions() !== undefined && promptField() !== undefined, "the new chat connects");
  return {
    starts,
    posts,
    /// The tab's unsent text as the host keeps it now: the last `chat.unsentDraft` (AgentUnsentDrafts `typed`).
    hostDraft: () =>
      posts.filter((post) => post.method === "chat.unsentDraft").at(-1)?.params.text as string | undefined,
    answer: () => act(async () => settle?.({ ok: true, value: { machine: "paint-dev" } })),
    fail: (retryable = false, code = "cloud_start_failed") =>
      act(async () =>
        settle?.({
          ok: false,
          error: { code, userMessage: "The machine stopped answering.", retryable },
        }),
      ),
  };
}

/// The host closed this tab (the chat opened on its machine).
async function closeTab() {
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
}

const bubbles = () => [...host.querySelectorAll(".cv-user__bubble")].map((bubble) => bubble.textContent ?? "");

/// Cloud picked, the prompt sent: the start is out.
async function startInCloud() {
  const pane = await mount();
  await until(() => debug().runMode("cloud").runMode === "cloud", "Cloud is offered and picked");
  await typeInto(PROMPT);
  await pressSend();
  await until(() => pane.starts.length === 1, "the send starts the chat in Cloud");
  expect(pane.starts[0]!.task).toBe(PROMPT);
  return pane;
}

async function typeInto(text: string) {
  await act(async () => void promptField()!.type(text));
  await until(() => composerText() === text, "the composer takes what is typed");
}
const typeWhileStarting = typeInto;

/// Return in the prompt, as the person sends.
async function pressSend() {
  const editable = promptElement()!.querySelector<HTMLElement>("[contenteditable]")!;
  await act(async () => {
    editable.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  await tick();
}

test("the composer stays focusable and typable while a Cloud chat starts", async () => {
  await startInCloud();
  // The box is not inert, and the sent prompt left it: it shows as the message, not as a draft.
  expect(composerBox()?.hasAttribute("inert")).toBe(false);
  expect(promptElement()?.closest("[inert]")).toBeNull();
  await until(() => composerText() === "", "the sent prompt leaves the composer");
  await act(async () => promptField()!.focus());
  expect(promptElement()?.contains(dom.window.document.activeElement)).toBe(true);
  await typeWhileStarting(TYPED);
}, 60_000);

test("a second Send while the start is out starts no second chat and keeps the text", async () => {
  const pane = await startInCloud();
  await typeWhileStarting(TYPED);
  // Return again, still on Cloud: no second start.
  await pressSend();
  expect(pane.starts.length).toBe(1);
  expect(composerText()).toBe(TYPED);
  // The Where menu is reachable now: picking This Mac and pressing Return starts no chat here either,
  // which the host would close with this tab when the Cloud chat opens.
  await until(() => debug().runMode("persistent").runMode === "persistent", "This Mac is picked");
  await pressSend();
  for (let step = 0; step < 20; step += 1) await tick();
  expect(pane.starts.length).toBe(1);
  expect(bubbles().some((text) => text.includes(TYPED))).toBe(false);
  expect(composerText()).toBe(TYPED);
}, 60_000);

test("the sending page hands the host what is typed during the start at once, and never the prompt", async () => {
  const pane = await startInCloud();
  const sentAt = pane.posts.findIndex((post) => post.method === "cloud.startChat");
  await act(async () => void promptField()!.type(TYPED));
  // At once, not on the 300 ms throttle: the host may open the chat and close this tab any moment.
  for (let step = 0; step < 3; step += 1) await tick();
  expect(pane.hostDraft()).toBe(TYPED);
  // Only what was typed: the prompt left the composer with the Send, so the host never keeps it.
  const during = pane.posts.slice(sentAt).filter((post) => post.method === "chat.unsentDraft");
  expect(during.some((post) => String(post.params.text).includes(PROMPT))).toBe(false);
  // The page keeps no copy of its own: another pane may not share its storage.
  const stored = Object.keys(dom.window.localStorage).map((key) => dom.window.localStorage.getItem(key) ?? "");
  expect(stored.some((value) => value.includes(TYPED))).toBe(false);
}, 60_000);

test("each started chat's composer gets its own start's draft from its seed, never sent", async () => {
  // Two starts of the same prompt, each typed into while it ran.
  const first = await startInCloud();
  await typeWhileStarting("first tab's note");
  for (let step = 0; step < 3; step += 1) await tick();
  const firstKept = first.hostDraft();
  await first.answer();
  await closeTab();
  const second = await startInCloud();
  await typeWhileStarting("second tab's note");
  for (let step = 0; step < 3; step += 1) await tick();
  const secondKept = second.hostDraft();
  await second.answer();
  await closeTab();
  expect([firstKept, secondKept]).toEqual(["first tab's note", "second tab's note"]);

  // The host seeds each started chat with its own tab's text: the second opens first here.
  await mount({ prompt: PROMPT, draft: secondKept });
  await until(() => bubbles().some((text) => text.includes(PROMPT)), "the seeded prompt went");
  await until(() => composerText() === "second tab's note", "the second chat's composer holds its draft");
  for (let step = 0; step < 5; step += 1) await tick();
  expect(composerText()).toBe("second tab's note");
  expect(bubbles().some((text) => text.includes("note"))).toBe(false);
  await closeTab();
  await mount({ prompt: PROMPT, draft: firstKept });
  await until(() => composerText() === "first tab's note", "the first chat's composer holds its own draft");
  for (let step = 0; step < 5; step += 1) await tick();
  expect(composerText()).toBe("first tab's note");
}, 120_000);

test("a chat started from attachments alone gets its draft too", async () => {
  const image: Record<string, unknown> = {
    id: "shot-1",
    kind: "image",
    name: "shot.png",
    mimeType: "image/png",
    size: 4,
    data: "iVBORw==",
  };
  await mount({ prompt: "", promptAttachments: [image], draft: TYPED });
  await until(() => composerText() === TYPED, "the composer holds the draft the seed carries");
  for (let step = 0; step < 5; step += 1) await tick();
  expect(composerText()).toBe(TYPED);
}, 60_000);

test("a start sent again after a sign-in takes its prompt out of the composer while it runs", async () => {
  const pane = await startInCloud();
  await pane.fail(false, "not_signed_in");
  await until(() => composerText() === PROMPT, "the prompt is back for the sign-in");
  const signIn = () => host.querySelector<HTMLButtonElement>(".acpmux-cloud-start__sign-in");
  await until(() => signIn() !== null, "the failure offers Sign in");
  await act(async () => signIn()!.click());
  await until(() => pane.starts.length === 2, "the sign-in sends the start again");
  expect(pane.starts[1]!.method).toBe("cloud.signIn");
  const sentAt = pane.posts.findIndex((post) => post.method === "cloud.signIn");
  // The prompt is the start's message now, as on the first Send: the composer holds only new text.
  await until(() => composerText() === "", "the resent prompt leaves the composer");
  await typeWhileStarting(TYPED);
  for (let step = 0; step < 3; step += 1) await tick();
  expect(pane.hostDraft()).toBe(TYPED);
  const during = pane.posts.slice(sentAt).filter((post) => post.method === "chat.unsentDraft");
  expect(during.some((post) => String(post.params.text).includes(PROMPT))).toBe(false);
  // It failed: the prompt comes back in front of what was typed.
  await pane.fail();
  await until(() => composerText() === `${PROMPT}\n\n${TYPED}`, "the prompt is back, the typed text after it");
}, 60_000);

test("a failed start puts the prompt back in front of what was typed", async () => {
  const pane = await startInCloud();
  await typeWhileStarting(TYPED);
  await pane.fail();
  await until(() => composerText() === `${PROMPT}\n\n${TYPED}`, "the prompt is back, the typed text after it");
}, 60_000);

test("Retry on a failed start sends its prompt alone, under the same key, and keeps what was typed", async () => {
  const pane = await startInCloud();
  await typeWhileStarting(TYPED);
  await pane.fail(true);
  await until(() => composerText() === `${PROMPT}\n\n${TYPED}`, "the prompt is back, the typed text after it");
  const retry = () => host.querySelector<HTMLButtonElement>(".acpmux-cloud-start__retry");
  await until(() => retry() !== null, "the failure offers Retry");
  await act(async () => retry()!.click());
  await until(() => pane.starts.length === 2, "Retry starts again");
  expect(pane.starts[1]!.task).toBe(PROMPT);
  expect(pane.starts[1]!.key).toBe(pane.starts[0]!.key);
  await until(() => composerText() === TYPED, "the typed text stays, unsent");
}, 60_000);

/// A paste into the prompt, as the person's Cmd-V lands.
async function pasteInto(clipboard: { files?: File[]; text?: string }) {
  const editable = promptElement()!.querySelector<HTMLElement>("[contenteditable]")!;
  const paste = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  const files = clipboard.files ?? [];
  Object.defineProperty(paste, "clipboardData", {
    value: {
      files,
      items: files.map((file) => ({ kind: "file", type: file.type, getAsFile: () => file })),
      types: [...(files.length ? ["Files"] : []), ...(clipboard.text !== undefined ? ["text/plain"] : [])],
      getData: (type: string) => (type === "text/plain" ? (clipboard.text ?? "") : ""),
    },
  });
  await act(async () => void editable.dispatchEvent(paste));
  for (let step = 0; step < 5; step += 1) await tick();
}
const chipsShown = () => host.querySelectorAll(".acpmux-composer-box [data-attachment-id], .acpmux-attachment").length;
const note = () => host.querySelector(".acpmux-attachment-note")?.textContent ?? "";

test("a file pasted during the start is refused with a note, never a chip the started chat would lose", async () => {
  await startInCloud();
  await until(() => composerText() === "", "the sent prompt leaves the composer");
  await pasteInto({ files: [new File(["{}"], "notes.json", { type: "application/json" })] });
  expect(chipsShown()).toBe(0);
  expect(note()).toContain("Cloud chat opens");
  // Typing stays open.
  await typeWhileStarting(TYPED);
}, 60_000);

test("a large paste during the start stays text; one past the field's limit is refused with a note", async () => {
  const pane = await startInCloud();
  await until(() => composerText() === "", "the sent prompt leaves the composer");
  // Past the chip's limit, within what the field draws as text: it goes in as text, which the host carries.
  const large = "word ".repeat(4_000).trim();
  await pasteInto({ text: large });
  expect(chipsShown()).toBe(0);
  await until(() => composerText() === large, "the large paste is the prompt's text");
  for (let step = 0; step < 3; step += 1) await tick();
  expect(pane.hostDraft()).toBe(large);
  // Past what the field draws as text: refused, and the note says so.
  await pasteInto({ text: "x".repeat(250_000) });
  expect(chipsShown()).toBe(0);
  expect(composerText()).toBe(large);
  expect(note()).toContain("Cloud chat opens");
}, 60_000);

test("chips the page adds during the start are refused with the same note: a design highlight, a transcript selection", async () => {
  await startInCloud();
  await until(() => composerText() === "", "the sent prompt leaves the composer");
  const bridge = (dom.window as unknown as { cmuxAcpmuxBridge?: { designSelection?(value: unknown): void } })
    .cmuxAcpmuxBridge;
  await act(async () =>
    bridge?.designSelection?.({ id: "pick-1", name: "Sidebar header", text: "<header>…</header>" }),
  );
  for (let step = 0; step < 3; step += 1) await tick();
  expect(chipsShown()).toBe(0);
  expect(note()).toContain("Cloud chat opens");
  const attachSelection = actions()?.["chat.attachSelection"] as ((params: unknown) => Promise<unknown>) | undefined;
  expect(attachSelection).toBeDefined();
  await act(async () => void (await attachSelection!({ text: "a line of the transcript worth quoting" })));
  for (let step = 0; step < 3; step += 1) await tick();
  expect(chipsShown()).toBe(0);
  expect(note()).toContain("Cloud chat opens");
  await typeWhileStarting(TYPED);
}, 60_000);

test("`!` typed during the start stays text the started chat gets, not shell mode it would lose", async () => {
  const pane = await startInCloud();
  await until(() => composerText() === "", "the sent prompt leaves the composer");
  // As the person types it: the `!` goes through the field's before-input first, where shell mode starts.
  const field = promptField() as unknown as { insertTyped(text: string): void };
  await act(async () => field.insertTyped("!"));
  await act(async () => field.insertTyped("ls the fixtures"));
  for (let step = 0; step < 3; step += 1) await tick();
  expect(host.querySelector(".acpmux-composer-box textarea")).toBeNull();
  await until(() => composerText() === "!ls the fixtures", "the `!` stays the prompt's text");
  for (let step = 0; step < 3; step += 1) await tick();
  expect(pane.hostDraft()).toBe("!ls the fixtures");
}, 60_000);
