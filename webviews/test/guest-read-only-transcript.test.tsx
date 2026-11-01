// l10n-allow-file: test fixtures.
// A read-only transcript (conversation/readOnly.ts, the guest page's): every record kind that has
// owner actions draws without them, even with every turn action and a native host present. The
// same rows drawn normally do show them, so the test proves the boundary, not missing fixtures.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
const { translate } = await import("../src/agent-session/acpmux/i18n");

afterAll(() => {
  setChipHost(undefined);
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

// A host that answers every chip question as the owner's machine would: the paths are in the
// project, so a normal transcript draws them as buttons that open there.
const hostCalls: string[] = [];
setChipHost(async (method, params) =>
  hostCalls.push(method) && method === "link.inspect"
    ? {
        paths: Object.fromEntries(
          ((params.paths as string[]) ?? []).map((path) => [path, { place: "root", folder: false }]),
        ),
        urls: {},
      }
    : undefined,
);

const AT = Date.UTC(2026, 9, 6, 9, 0, 0);
const row = (id: string, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: AT,
  kind,
  ...fields,
});
const message = {
  name: "reviewer",
  sessionId: "chat-reviewer",
  msgId: "m-1",
  threadId: "t-1",
  text: "Looks good, one nit in src/upload.ts",
  raw: "reviewer -> me: Looks good, one nit in src/upload.ts",
};

/** One row of every kind that carries an owner action. */
const ROWS: AcpmuxRow[] = [
  // Another agent's message, a steer the agent has not read: Reply, Send now, the sender's chat, Retry, Pin.
  row("user-1", "user", {
    seq: 1,
    text: message.raw,
    incoming: { kind: "message", message },
    steer: "waiting",
    steerPromptId: "p-steer",
  }),
  // The person's prompt: Edit, Retry, Fork, Pin; a steer still waiting: its queue controls.
  row("user-2", "user", { seq: 2, text: "Fix the flaky test", steer: "waiting", steerPromptId: "p-2" }),
  // A prompt that waits behind a harness switch: Cancel.
  row("user-3", "user", { seq: 3, text: "Then run it again", status: "Waiting", queued: "p-3" }),
  // A prompt that failed to send: Retry and the rest of its failure card.
  row("user-4", "user", { seq: 4, text: "And on Linux", failed: true, delivery: { state: "failed" } as never }),
  // A reply naming a file in the project: a path chip that opens on the owner's machine.
  row("assistant-5", "assistant", { seq: 5, text: "Edited `src/upload.ts` and [the test](src/upload.test.ts)." }),
  // The turn's footer: Retry (failed), Fork, Pin.
  row("summary-6", "turnSummary", {
    seq: 6,
    status: "failed",
    error: "rate limited",
    prompt: "Fix the flaky test",
    retryRowId: "user-2",
    text: "Done",
  }),
  // A pending ask: Allow, Reject.
  row("permission-7", "permission", {
    permission: {
      permissionId: "perm-1",
      title: "bun test src/upload.test.ts",
      pending: true,
      options: [
        { id: "allow", name: "Allow once", allow: true, kind: "allow_once" },
        { id: "reject", name: "Reject", allow: false, kind: "reject_once" },
      ],
    } as never,
  }),
  // Another agent's message waiting in the queue: Reply and its menu.
  row("queued-8", "queuedMessage", {
    text: message.raw,
    incoming: { kind: "message", message: { ...message, msgId: "m-2" } },
    queuedMessage: { promptId: "p-8", next: true },
  }),
  // A paused agent pair: Resume.
  row("pair-9", "agentPair", {
    agentPair: {
      peer: "peer-1",
      peerName: "Reviewer",
      reason: "alternating",
      count: 10,
      held: [],
      released: [],
      dropped: [],
    } as never,
  }),
  // Suggested tasks: Start, Here, Dismiss.
  row("offer-10", "sessionOffer", {
    offers: [
      { offerId: "o-1", title: "Add a fake clock", prompt: "Add a fake clock", cwd: "/repo", worktree: true } as never,
    ],
  }),
  // Chats this one started: Open.
  row("started-11", "startedSessions", {
    started: [{ sessionId: "child-1", title: "Child", state: "running" } as never],
  }),
  // A turn's local page: Open in a cmux tab.
  row("preview-12", "preview", { text: "http://localhost:5173/" }),
  // A task's result sent back as a prompt: opens the chat it came from.
  row("user-13", "user", {
    seq: 13,
    text: "result",
    received: { offerId: "o-1", childSessionId: "child-1", title: "Fake clock" },
  }),
  // A background shell that ended: Open in terminal.
  row("bg-14", "backgroundTask", {
    backgroundTask: { toolCallId: "call-bg", command: "bun run dev", state: "completed" },
  }),
  // A reply with a web image: Load image (a host fetch).
  row("assistant-15", "assistant", { seq: 15, text: "![chart](https://example.com/chart.png)" }),
];

/** Every turn action present, as the owner's pane provides them. */
const ownerActions = {
  fork: () => undefined,
  forkAny: true,
  promptTurns: new Map([["user-2", 2]]),
  edit: { seqs: new Map([["user-2", 1]]), send: async () => true },
  retry: () => undefined,
  resume: async () => undefined,
  restartSubagent: () => undefined,
  reauthenticate: () => undefined,
  unsteer: async () => true,
} as never;

/** The names of the controls a reader could act with: buttons, links, fields and menu triggers. */
const OWNER_CONTROLS = [
  translate("message.reply"),
  translate("steer.sendNow"),
  translate("composer.queueEditMessage"),
  translate("composer.queueActions"),
  translate("message.edit"),
  translate("turn.retry"),
  translate("turn.fork"),
  translate("message.pin"),
  translate("agentPair.resume"),
  translate("shell.openInTerminal"),
  translate("image.load"),
  "Allow once",
  "Reject",
];

async function draw(readOnly: boolean) {
  hostCalls.length = 0;
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={ownerActions}>
        <VirtualTranscript
          rows={ROWS}
          sessionId="guest-chat"
          expanded={new Set()}
          onToggleActivity={() => undefined}
          readOnly={readOnly}
        />
      </TurnActionsContext.Provider>,
    ),
  );
  // Path chips ask the host where their files are; let those answers draw.
  await act(async () => {
    for (let tick = 0; tick < 8; tick += 1) await Promise.resolve();
  });
  // A fold's toggle (aria-expanded) and a plain web link (it opens in the reader's own browser) are
  // the reader's own; every other control is counted.
  const controls = [...host.querySelectorAll("button, a[href], [role=link], [role=button], textarea, input")].filter(
    (element) => !element.hasAttribute("aria-expanded") && !/^https?:/.test(element.getAttribute("href") ?? ""),
  );
  const named = controls.map((element) =>
    [element.getAttribute("aria-label"), element.getAttribute("title"), element.textContent]
      .filter(Boolean)
      .join(" | ")
      .trim(),
  );
  const pathButtons = host.querySelectorAll("button.cv-chip.is-path").length;
  await act(async () => root.unmount());
  host.remove();
  return { named, pathButtons, hostCalls: [...hostCalls] };
}

const owned = (named: string[]) =>
  OWNER_CONTROLS.filter((control) => named.some((name) => name.split(" | ").some((part) => part.trim() === control)));

test("drawn normally, the rows carry the owner's controls (the fixtures reach them)", async () => {
  const { named, pathButtons } = await draw(false);
  expect(owned(named).length).toBeGreaterThanOrEqual(6);
  expect(pathButtons).toBeGreaterThan(0);
});

test("read only, no row draws a control that acts on the owner's machine or daemon", async () => {
  const { named, pathButtons, hostCalls: asked } = await draw(true);
  expect(owned(named)).toEqual([]);
  expect(pathButtons).toBe(0);
  // Nor asks the owner's host anything (where files are, images to fetch).
  expect(asked).toEqual([]);
  // Every control left is the reader's own (open or close a fold, copy): listed here by name, so a
  // new control in a row fails this test until someone decides it is safe for a guest.
  const local = [
    translate("turn.copy"),
    translate("turn.failure.copyError"),
    translate("message.label", { from: "reviewer", to: translate("message.self") }),
  ];
  const left = named.map((name) => name.split(" | ")[0]!.trim()).filter((name) => !local.includes(name));
  expect(left).toEqual([]);
});
