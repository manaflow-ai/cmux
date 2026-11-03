// l10n-allow-file: test fixtures.
// The guest page reaches no owner host, as a class (design/chat-multiplayer.md section 5): a
// read-only transcript over every row kind that has owner actions or host reads, with a spy behind
// every way the pane reaches its host (native calls, the WebKit handler, the page host, chip calls,
// the pane's action table, the message-menu handler and source, the bookmark transport) and a spy
// in every owner action context (turn actions, shell, subagents, sessions, artifacts, images,
// render pages, background, sign in, accounts, avatars). Every element is hovered, clicked and
// right-clicked; then a frame and the stores' batching timers pass. The spies must see nothing.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/g/c2hhcmUtMTIzNDU2Nzg",
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
    constructor(private readonly callback: (entries: unknown[]) => void) {}
    // Everything is in view: lazy loads (media near the viewport) would start here.
    observe(target: Element) {
      this.callback([{ target, isIntersecting: true, intersectionRatio: 1 }]);
    }
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|MouseEvent|PointerEvent|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = [...Object.keys(replacements), "setTimeout", "setInterval", "clearTimeout", "clearInterval"].map(
  (key) => [key, key in scope, scope[key]] as const,
);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

// Fake timers for the page's code: a timer runs when the test advances, not after real time, so
// "nothing was asked after the batching timers" needs no fixed wait.
type Timer = { run: () => void; repeat: boolean };
const timers = new Map<number, Timer>();
let nextTimer = 1;
const fakeTimer =
  (repeat: boolean) =>
  (fn: (...args: unknown[]) => void, _ms?: number, ...args: unknown[]) => {
    const id = nextTimer++;
    timers.set(id, { run: () => fn(...args), repeat });
    return id;
  };
const clearTimer = (id: unknown) => void timers.delete(id as number);
Object.assign(scope, {
  // Frames are timers here too: one runs per advance.
  requestAnimationFrame: (fn: (now: number) => void) => fakeTimer(false)(() => fn(0)),
  cancelAnimationFrame: clearTimer,
  setTimeout: fakeTimer(false),
  setInterval: fakeTimer(true),
  clearTimeout: clearTimer,
  clearInterval: clearTimer,
});
/** Runs every timer due now once (an interval stays for the next advance). */
function advanceTimers() {
  // A snapshot: timers set while these run wait for the next advance.
  for (const [id, timer] of Array.from(timers)) {
    if (!timer.repeat) timers.delete(id);
    timer.run();
  }
}

/** Every call any spy saw, as `<route> <what>`. */
const calls: string[] = [];
const spy =
  (route: string) =>
  (...args: unknown[]) => {
    const first = args[0];
    const what =
      typeof first === "string"
        ? first
        : first && typeof first === "object"
          ? String((first as { method?: unknown }).method ?? Object.keys(first).join(","))
          : String(first ?? "");
    calls.push(`${route} ${what}`.trim());
    return Promise.resolve(undefined);
  };

// The app's routes to its host, all present as they would be in cmux: the WebKit handlers, the
// shared page host's reply handler, and the pane's action table.
const win = dom.window as unknown as Record<string, any>;
win.webkit = {
  messageHandlers: new Proxy({}, { get: (_, name) => ({ postMessage: spy(`webkit.${String(name)}`) }) }),
};
win.cmuxAcpmuxActions = new Proxy({}, { get: (_, name) => spy(`actions.${String(name)}`) });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { GuestPage } = await import("../src/agent-session/guest/GuestPage");
const { installGuestHost } = await import("../src/agent-session/guest/guestHost");
const { setChipHost, callChipHost } = await import("../src/agent-session/acpmux/chips/host");
const { setNativeHost, postNative } = await import("../src/agent-session/acpmux/native");
const { setMessageMenuSource, installMessageMenuReporter } =
  await import("../src/agent-session/acpmux/conversation/messageMenu");
const { setBookmarkTransport } = await import("../src/agent-session/acpmux/threadMinimap/bookmarks");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
const { ShellActionsContext } = await import("../src/agent-session/acpmux/shell/ShellRow");
const { SubagentNavContext, SubagentPaneContext, SubagentStopContext } =
  await import("../src/agent-session/acpmux/subagents/SubagentGroup");
const { ImageViewerContext } = await import("../src/agent-session/acpmux/conversation/imageViewerContext");
const { ArtifactContext } = await import("../src/agent-session/acpmux/conversation/artifactPreview");
const { RunInBackgroundContext } = await import("../src/agent-session/acpmux/conversation/runInBackground");
const { SignInContext } = await import("../src/agent-session/acpmux/signIn");
const { StartedMentionsContext } = await import("../src/agent-session/acpmux/started/StartedSessionCard");
const { AvatarContext } = await import("../src/pages/home-channels/avatars");
const { askingRecords, fakeRoom, joinFrames, memoryStorage } =
  await import("../src/agent-session/guest/fixtures/liveChat");

afterAll(() => {
  // Bun shares modules across test files: put every host and transport back as the pane has them.
  removeReporter();
  setNativeHost(undefined);
  setChipHost(undefined);
  setBookmarkTransport(undefined);
  setMessageMenuSource(undefined);
  timers.clear();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("the guest host routes nothing to the app: native, chip and action calls all refuse", async () => {
  calls.length = 0;
  installGuestHost();
  await expect(postNative("link.openPath", { path: "/x" })).rejects.toBeDefined();
  expect(await callChipHost("image.load", { src: "https://example.com/a.png" })).toBeUndefined();
  expect(win.cmuxAcpmuxActions).toBeUndefined();
  expect(calls).toEqual([]);
});

// Then a spy behind every route and every owner provider, set AFTER the guest host as a page that
// forgot one would: the read-only boundary alone must keep the transcript from reaching them.
let removeReporter = () => undefined as void;
function installSpies() {
  installGuestHost();
  win.cmuxAcpmuxActions = new Proxy({}, { get: (_, name) => spy(`actions.${String(name)}`) });
  setNativeHost(spy("native") as never);
  setChipHost(spy("chip") as never);
  setMessageMenuSource((rowId) => (calls.push(`menuSource ${rowId}`), { rowId, kind: "answer" }) as never);
  setBookmarkTransport({ get: spy("bookmarks.get") as never, set: spy("bookmarks.set") as never });
  removeReporter();
  removeReporter = installMessageMenuReporter(dom.window.document, () => ({
    postMessage: spy("messageMenu.report"),
  }));
  calls.length = 0;
}

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
  text: "See https://github.com/acme/app/pull/12 and src/upload.ts",
  raw: "reviewer -> me: See https://github.com/acme/app/pull/12 and src/upload.ts",
};
const agent = (id: string, state: string) =>
  ({ id, parent: null, name: `Agent ${id}`, state, startedAt: AT, task: "Look around" }) as never;

/** Every row kind with an owner action or a host read. */
const ROWS: AcpmuxRow[] = [
  row("user-1", "user", {
    seq: 1,
    text: message.raw,
    incoming: { kind: "message", message },
    steer: "waiting",
    steerPromptId: "p-1",
  }),
  row("user-2", "user", { seq: 2, text: "Fix #12 in acme/app", steer: "waiting", steerPromptId: "p-2" }),
  row("user-3", "user", { seq: 3, text: "Then again", status: "Waiting", queued: "p-3" }),
  row("user-4", "user", { seq: 4, text: "On Linux", failed: true, delivery: { state: "failed" } as never }),
  // A message a Chief's turn sent: its line would ask the host for the Chief's face (chiefFace.ts).
  row("user-chief", "user", {
    seq: 4,
    text: "Chief -> me: Check the upload retry",
    incoming: {
      kind: "message",
      message: {
        name: "optchat-home-1",
        chief: "chief-1",
        text: "Check the upload retry",
        raw: "Chief -> me: Check the upload retry",
      },
    },
  }),
  row("assistant-5", "assistant", {
    seq: 5,
    text: [
      "Edited `src/upload.ts` for Clock child, see [the test](src/upload.test.ts) and https://github.com/acme/app/pull/12.",
      "",
      "![shot](/Users/owner/repo/shot.png) ![web](https://example.com/chart.png)",
      "",
      "![clip](/Users/owner/repo/demo.mp4) ![web clip](https://example.com/demo.mp4)",
    ].join("\n"),
  }),
  row("summary-6", "turnSummary", {
    seq: 6,
    status: "failed",
    error: "rate limited",
    prompt: "x",
    retryRowId: "user-2",
    text: "Done",
    // The answer the footer's More (…) menu names.
    answerId: "assistant-5",
  }),
  row("permission-7", "permission", {
    permission: {
      permissionId: "perm-1",
      title: "bun test",
      pending: true,
      options: [{ id: "allow", name: "Allow once", allow: true, kind: "allow_once" }],
    } as never,
  }),
  row("queued-8", "queuedMessage", {
    text: message.raw,
    incoming: { kind: "message", message: { ...message, msgId: "m-2" } },
    queuedMessage: { promptId: "p-8", next: true },
  }),
  row("pair-9", "agentPair", {
    agentPair: { peer: "p", peerName: "Reviewer", reason: "alternating", count: 3, held: [] } as never,
  }),
  row("offer-10", "sessionOffer", {
    offers: [{ offerId: "o-1", title: "Clock", prompt: "Clock", cwd: "/repo", worktree: true } as never],
  }),
  row("started-11", "startedSessions", { started: [{ sessionId: "c-1", title: "Child", state: "running" } as never] }),
  row("preview-12", "preview", { text: "http://localhost:5173/" }),
  row("user-13", "user", { seq: 13, text: "r", received: { offerId: "o-1", childSessionId: "c-1", title: "Clock" } }),
  row("bg-14", "backgroundTask", { backgroundTask: { toolCallId: "call-bg", command: "bun dev", state: "completed" } }),
  row("shell-15", "userShell", {
    shell: {
      id: "s-1",
      command: "npm test",
      startedAt: AT,
      status: "running",
      output: "ok\n",
      truncated: false,
    } as never,
  }),
  row("subagent-16", "subagent", { subagents: [agent("a-1", "running")] }),
  row("activity-17", "activity", {
    items: [
      {
        kind: "tool",
        text: "Wrote shot",
        tool: {
          id: "tool-img",
          title: "Write /Users/owner/repo/out.png",
          kind: "edit",
          status: "completed",
          locations: [{ path: "/Users/owner/repo/out.png" }, { path: "/Users/owner/repo/out.mp4" }],
        },
      } as never,
    ],
  }),
  row("edited-18", "editedFiles", { ended: true }),
];

/** Owner contexts, each a spy, as the owner's pane provides them. */
function OwnerProviders({ children }: { children: React.ReactNode }) {
  const turn = {
    fork: spy("turn.fork"),
    forkAny: true,
    promptTurns: new Map([["user-2", 2]]),
    edit: { seqs: new Map([["user-2", 1]]), send: spy("turn.edit") },
    retry: spy("turn.retry"),
    resume: spy("turn.resume"),
    restartSubagent: spy("turn.restartSubagent"),
    reauthenticate: spy("turn.reauthenticate"),
    unsteer: spy("turn.unsteer"),
    switchModel: spy("turn.switchModel"),
  };
  return (
    <TurnActionsContext.Provider value={turn as never}>
      <ShellActionsContext.Provider value={{ stop: spy("shell.stop"), openInTerminal: spy("shell.open") } as never}>
        <SubagentNavContext.Provider value={spy("subagent.nav") as never}>
          <SubagentPaneContext.Provider value={spy("subagent.pane") as never}>
            <SubagentStopContext.Provider value={spy("subagent.stop") as never}>
              <ImageViewerContext.Provider value={spy("image.viewer") as never}>
                <ArtifactContext.Provider value={spy("artifact.open") as never}>
                  <RunInBackgroundContext.Provider value={spy("background.run") as never}>
                    <SignInContext.Provider value={{ signedOut: { claude: "login" }, logIn: spy("signIn") } as never}>
                      <StartedMentionsContext.Provider
                        value={
                          {
                            mentions: [
                              { text: "Clock child", sessionId: "c-1", title: "Clock child", state: "running" },
                            ],
                            open: spy("mention.open"),
                          } as never
                        }
                      >
                        <AvatarContext.Provider
                          value={{ picture: spy("avatar.picture"), watch: () => () => undefined } as never}
                        >
                          {children}
                        </AvatarContext.Provider>
                      </StartedMentionsContext.Provider>
                    </SignInContext.Provider>
                  </RunInBackgroundContext.Provider>
                </ArtifactContext.Provider>
              </ImageViewerContext.Provider>
            </SubagentStopContext.Provider>
          </SubagentPaneContext.Provider>
        </SubagentNavContext.Provider>
      </ShellActionsContext.Provider>
    </TurnActionsContext.Provider>
  );
}

/** Lets microtasks, frames and every timer the page set (the link and pull request stores batch
 *  their host asks on 50 ms timers; the pull request card polls) run, several rounds over. */
async function settle() {
  await act(async () => {
    for (let round = 0; round < 6; round += 1) {
      for (let tick = 0; tick < 4; tick += 1) await Promise.resolve();
      advanceTimers();
    }
  });
}

/** Hovers, clicks and right-clicks every element in `host`, then lets everything settle. */
async function touchEverything(host: HTMLElement) {
  const fire = (element: Element, type: string, Init: typeof MouseEvent = dom.window.MouseEvent as never) =>
    element.dispatchEvent(new Init(type, { bubbles: true, cancelable: true, button: type === "contextmenu" ? 2 : 0 }));
  for (const element of host.querySelectorAll("*")) {
    await act(async () => {
      for (const type of ["pointerover", "pointerenter", "mouseover", "mouseenter", "focusin", "contextmenu"])
        fire(element, type);
    });
  }
  await settle();
  // Clicks may open folds that draw more controls: two passes.
  for (let pass = 0; pass < 2; pass += 1)
    for (const element of host.querySelectorAll("button, a, [role=button], [role=link], summary, [tabindex]")) {
      await act(async () => {
        fire(element, "click");
        fire(element, "contextmenu");
        element.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
      });
    }
  await settle();
}

test("a read-only transcript over every owner row kind reaches no host and no owner action", async () => {
  installSpies();
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  await act(async () =>
    root.render(
      <OwnerProviders>
        <VirtualTranscript
          rows={ROWS}
          sessionId="guest-chat"
          expanded={new Set(["activity-17"])}
          onToggleActivity={() => undefined}
          readOnly
        />
      </OwnerProviders>,
    ),
  );
  await settle();
  await touchEverything(host);
  expect(calls).toEqual([]);
  await act(async () => root.unmount());
  host.remove();
});

test("the guest page itself, joined and live, reaches no host and no owner action", async () => {
  installSpies();
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  await act(async () =>
    root.render(
      <OwnerProviders>
        <GuestPage
          shareId="c2hhcmUtMTIzNDU2Nzg"
          guestId="g1"
          storage={memoryStorage()}
          redeem={() => new Promise(() => undefined)}
          attempt={() => "0".repeat(32)}
          socketUrl="wss://room.test/guest"
          openSocket={fakeRoom(joinFrames(askingRecords()))}
        />
      </OwnerProviders>,
    ),
  );
  await settle();
  await touchEverything(host);
  expect(calls).toEqual([]);
  await act(async () => root.unmount());
  host.remove();
  removeReporter();
});
