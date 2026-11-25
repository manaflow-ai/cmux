// l10n-allow-file: synthetic refusal reasons and session ids, not shipped UI.
// cmux#55788: a chat on this Mac has a Send to Cloud button in its header. A click runs the app's Move to
// Cloud for that chat (the title menu's row); a greyed one says why and runs nothing; a chat already in
// Cloud, or with no move offered, has none. The native tab row carries the same button.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ComponentProps } from "react";
import { createRoot, type Root } from "react-dom/client";
import { ChatHeaderTools } from "../src/agent-session/acpmux/header/ChatHeaderTools";
import { cloudSendButton } from "../src/agent-session/acpmux/header/cloudSendButton";
import { headerState, setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import type { NativeRowTool } from "../src/agent-session/acpmux/header/nativeRowTools";
import { configureQuickActions, quickActions } from "../src/agent-session/acpmux/header/quickActions";
import { translate } from "../src/agent-session/acpmux/i18n";
import { applyHostEvent } from "../src/agent-session/acpmux/pageHost";
import type { MoveView, PlaceState } from "../src/agent-session/acpmux/place/placeModel";
import { settleReact } from "./support/domTeardown";

const move = (over: Partial<MoveView> = {}): MoveView => ({
  session: "chat-1",
  direction: "toCloud",
  trigger: "person",
  from: "This Mac",
  to: "",
  state: "moving",
  step: "sync",
  stepIndex: 2,
  stepCount: 8,
  startedMs: 0,
  elapsedMs: 1000,
  budgetMs: 60000,
  overBudget: false,
  canCancel: true,
  finishing: false,
  runsAt: "local",
  carries: [],
  interruptsTurn: false,
  canRetry: false,
  ...over,
});
const local: PlaceState = { mode: "local", at: "local" };

test("the button shows only for a chat whose menu offers Move to Cloud", () => {
  // A Cloud chat offers Bring Back Local, never Move to Cloud: no button.
  expect(
    cloudSendButton({ session: "chat-1", offloads: ["bringBack"], reasons: {}, place: undefined }),
  ).toBeUndefined();
  expect(cloudSendButton({ session: "chat-1", offloads: [], reasons: {}, place: local })).toBeUndefined();
  // A new tab with no chat yet.
  expect(cloudSendButton({ session: undefined, offloads: ["move"], reasons: {}, place: local })).toBeUndefined();
  expect(cloudSendButton({ session: "chat-1", offloads: ["move"], reasons: {}, place: local })).toEqual({
    state: "ready",
  });
});

test("a move the app would refuse greys the button with the app's reason", () => {
  const reason = "Send a first message, then move this chat.";
  expect(cloudSendButton({ session: "chat-1", offloads: ["move"], reasons: { move: reason }, place: local })).toEqual({
    state: "refused",
    reason,
  });
});

test("the chat's own move to Cloud shows as moving; another chat's or a failed one does not", () => {
  const button = (m: MoveView) =>
    cloudSendButton({ session: "chat-1", offloads: ["move"], reasons: {}, place: { ...local, move: m } })?.state;
  expect(button(move())).toBe("moving");
  expect(button(move({ session: "chat-2" }))).toBe("ready");
  expect(button(move({ state: "failed", reason: "no network" }))).toBe("ready");
  expect(button(move({ direction: "toLocal" }))).toBe("ready");
});

let dom: JSDOM | undefined;
let root: Root | undefined;
let previousHeader: ReturnType<typeof headerState> | undefined;
let previousQuick: ReturnType<typeof quickActions> | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();

function mount() {
  previousHeader = headerState();
  previousQuick = quickActions();
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const replacements = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  configureQuickActions({ quickActions: ["terminal", "browser"] });
  setHeaderState({ lit: [], pullRequest: null });
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  return container;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  if (previousQuick) configureQuickActions({ quickActions: previousQuick });
  if (previousHeader) setHeaderState({ ...previousHeader, pullRequest: previousHeader.pullRequest ?? null });
  previousQuick = undefined;
  previousHeader = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, { had, value }] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  saved.clear();
});

async function render(props: Partial<ComponentProps<typeof ChatHeaderTools>>) {
  await act(async () =>
    root!.render(
      <ChatHeaderTools onTerminal={() => {}} onBrowser={() => {}} summary={null} menu={() => []} {...props} />,
    ),
  );
}

const cloudButton = (container: HTMLElement) => container.querySelector<HTMLButtonElement>("[data-cloud-send]");

test("a click on Send to Cloud runs the move once", async () => {
  const container = mount();
  const runs: string[] = [];
  await render({ cloudSend: { state: "ready", run: () => runs.push("move") } });
  const button = cloudButton(container)!;
  expect(button).not.toBeNull();
  expect(button.getAttribute("aria-label")).toBe(translate("header.sendToCloud"));
  expect(button.getAttribute("title")).toBe(translate("header.sendToCloudTip"));
  expect(button.getAttribute("aria-disabled")).toBeNull();
  await act(async () => button.click());
  expect(runs).toEqual(["move"]);
});

test("a greyed Send to Cloud says why and runs nothing; a running move says it is sending", async () => {
  const container = mount();
  const runs: string[] = [];
  const reason = "Send a first message, then move this chat.";
  await render({ cloudSend: { state: "refused", reason, run: () => runs.push("move") } });
  let button = cloudButton(container)!;
  expect(button.getAttribute("aria-disabled")).toBe("true");
  expect(button.getAttribute("title")).toBe(reason);
  await act(async () => button.click());
  await render({ cloudSend: { state: "moving", run: () => runs.push("move") } });
  button = cloudButton(container)!;
  expect(button.getAttribute("data-cloud-send")).toBe("moving");
  expect(button.getAttribute("aria-busy")).toBe("true");
  expect(button.getAttribute("title")).toBe(translate("header.sendingToCloud"));
  await act(async () => button.click());
  expect(runs).toEqual([]);
});

test("no Send to Cloud without a move to offer", async () => {
  const container = mount();
  await render({});
  expect(cloudButton(container)).toBeNull();
});

test("the native tab row carries Send to Cloud and runs it", async () => {
  const container = mount();
  let tools: NativeRowTool[] = [];
  const host = {
    enabled: true,
    callNative: async (_method: string, params: Record<string, unknown>) => {
      tools = params.tools as NativeRowTool[];
    },
  };
  const runs: string[] = [];
  await render({ nativeRowTools: host, cloudSend: { state: "ready", run: () => runs.push("move") } });
  // The native row draws it: no web button beside it.
  expect(cloudButton(container)).toBeNull();
  const tool = tools.find((item) => item.id === "cloudSend");
  expect(tool).toEqual(
    expect.objectContaining({ symbol: "icloud.and.arrow.up", enabled: true, label: translate("header.sendToCloud") }),
  );
  act(() => applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "cloudSend" } }));
  expect(runs).toEqual(["move"]);

  const reason = "Cloud is turned off by your organization.";
  await render({ nativeRowTools: host, cloudSend: { state: "refused", reason, run: () => runs.push("move") } });
  expect(tools.find((item) => item.id === "cloudSend")).toEqual(
    expect.objectContaining({ enabled: false, label: reason }),
  );
  act(() => applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "cloudSend" } }));
  expect(runs).toEqual(["move"]);
});
