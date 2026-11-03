// l10n-allow-file: synthetic contacts and permission replies used by connector tests.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../src/agent-session/acpmux/i18n";
import { setNativeHost } from "../src/agent-session/acpmux/native";
import {
  IMESSAGE_INITIAL,
  useIMessage,
  type IMessageData,
  type IMessageView,
} from "../src/agent-session/acpmux/session-info/imessage";
import { IMessageConnector } from "../src/agent-session/acpmux/session-info/IMessageConnector";
import { SessionInfo } from "../src/agent-session/acpmux/session-info/SessionInfo";
import { resetSessionInfoState } from "../src/agent-session/acpmux/session-info/sessionInfoState";
import { connectorsSection } from "../src/agent-session/acpmux/session-info/native/connectors";
import { NativeInfoActions } from "../src/agent-session/acpmux/session-info/native/model";

let dom: JSDOM | undefined;
let root: Root | undefined;
const saved = new Map<string, unknown>();
const scope = globalThis as Record<string, unknown>;

function install() {
  dom = new JSDOM("<main id=root></main>", { url: "http://localhost/", pretendToBeVisual: true });
  Object.defineProperty(dom.window.navigator, "platform", { value: "MacIntel" });
  const replacements: Record<string, unknown> = {
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
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  resetSessionInfoState();
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  setNativeHost(undefined);
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const button = (container: HTMLElement, text: string) =>
  [...container.querySelectorAll("button")].find((node) => node.textContent === text)!;

test("Connect is one Show more reveal away without MCP; permission steps precede all thread reads", async () => {
  const container = install();
  const calls: string[] = [];
  let data: IMessageData = { ...IMESSAGE_INITIAL };
  setNativeHost(async (method) => {
    calls.push(method);
    if (method === "imessage.connect") data = { ...data, status: "needs_full_disk_access" };
    if (method === "imessage.full_disk_access") data = { ...data, status: "needs_automation" };
    if (method === "imessage.skip_automation") data = { ...data, status: "connected" };
    if (method === "imessage.threads")
      data = {
        ...data,
        threads: [
          { chat_id: 2, title: "Maya", is_group: false, participants: ["maya@example.test"] },
          { chat_id: 1, title: "Dinner", is_group: true, participants: ["Maya", "Sam"] },
        ],
      };
    if (method === "imessage.disconnect") data = { ...IMESSAGE_INITIAL };
    return data;
  });
  await act(async () => {
    root = createRoot(container);
    root.render(<SessionInfo />);
  });
  expect(calls).toEqual(["imessage.status"]);
  expect(container.querySelector('[data-section="connectors"]')).toBeNull();
  const more = [...container.querySelectorAll("button")].find((node) =>
    node.textContent?.startsWith(translate("sessionInfo.changes.showMore")),
  )!;
  await act(async () => more.click());
  // Connectors stays folded until the person opens it; its meta says Connect iMessage.
  const header = [...container.querySelectorAll('[data-section="connectors"] button')].find((node) =>
    node.textContent?.startsWith(translate("rail.connectors")),
  ) as HTMLButtonElement;
  await act(async () => header.click());
  await act(async () => button(container, translate("imessage.connect")).click());
  expect(calls).toEqual(["imessage.status", "imessage.connect"]);
  await act(async () => button(container, translate("imessage.grantDisk")).click());
  expect(calls).not.toContain("imessage.threads");
  await act(async () => button(container, translate("question.skip")).click());
  expect(calls.slice(-2)).toEqual(["imessage.skip_automation", "imessage.threads"]);
  expect([...container.querySelectorAll(".acpmux-imessage-thread-name")].map((row) => row.textContent)).toEqual([
    "Maya",
    "Dinner",
  ]);
  expect(container.textContent).toContain(translate("imessage.sendClick"));
  expect(calls.some((method) => method.includes("send"))).toBe(false);
  await act(async () => button(container, translate("imessage.disconnect")).click());
  expect(container.textContent).not.toContain("maya@example.test");
  expect(container.querySelectorAll(".acpmux-imessage-thread")).toHaveLength(0);
});

test("permission events refresh status and a closed connected list reads no threads", async () => {
  const container = install();
  const calls: string[] = [];
  let data: IMessageData = { ...IMESSAGE_INITIAL, status: "connected", sends_enabled: true };
  setNativeHost(async (method) => {
    calls.push(method);
    return data;
  });
  await act(async () => {
    root = createRoot(container);
    root.render(<SessionInfo more />);
  });
  expect(calls).toEqual(["imessage.status"]);
  data = { ...data, status: "needs_full_disk_access", sends_enabled: false };
  await act(async () => dom!.window.dispatchEvent(new dom!.window.Event("cmux-imessage-changed")));
  expect(calls).toEqual(["imessage.status", "imessage.status"]);
  expect(container.textContent).toContain(translate("imessage.grantDisk"));
  await act(async () => root!.unmount());
  root = undefined;
  dom!.window.dispatchEvent(new dom!.window.Event("cmux-imessage-changed"));
  expect(calls).toHaveLength(2);
});

for (const stale of ["threads", "status"] as const) {
  test(`a pre-disconnect ${stale} reply cannot reconnect or repopulate contacts`, async () => {
    const container = install();
    const calls: string[] = [];
    const connected: IMessageData = {
      ...IMESSAGE_INITIAL,
      status: "connected",
      threads: [{ chat_id: 9, title: "Maya", is_group: false, participants: ["maya@example.test"] }],
    };
    let controller: IMessageView | undefined;
    let hold = false;
    let reply: ((value: IMessageData) => void) | undefined;
    const delayed = new Promise<IMessageData>((resolve) => {
      reply = resolve;
    });
    setNativeHost(async (method) => {
      calls.push(method);
      if (hold && method === `imessage.${stale}`) return delayed;
      return method === "imessage.disconnect" ? { ...IMESSAGE_INITIAL } : connected;
    });
    function Harness() {
      controller = useIMessage();
      return controller ? <IMessageConnector view={controller} /> : null;
    }
    await act(async () => {
      root = createRoot(container);
      root.render(<Harness />);
    });
    let pending: Promise<void> | undefined;
    if (stale === "threads") {
      hold = true;
      await act(async () => {
        pending = controller!.perform("threads");
      });
    } else {
      await act(async () => controller!.perform("threads"));
      expect(container.textContent).toContain("Maya");
      hold = true;
      await act(async () => dom!.window.dispatchEvent(new dom!.window.Event("cmux-imessage-changed")));
    }
    expect(calls.at(-1)).toBe(`imessage.${stale}`);
    await act(async () => controller!.perform("disconnect"));
    expect(controller!.data.status).toBe("not_connected");
    const afterDisconnect = calls.length;
    await act(async () => {
      reply!(connected);
      await delayed;
      await pending;
    });
    expect(controller!.data.status).toBe("not_connected");
    expect(controller!.data.threads).toEqual([]);
    expect(container.textContent).not.toContain("Maya");
    expect(calls.length).toBe(afterDisconnect);
  });
}

test("native rows retain Connect without MCP and connected contacts in reader order", async () => {
  const actions = new NativeInfoActions();
  const performed: string[] = [];
  const view = {
    data: { ...IMESSAGE_INITIAL },
    busy: false,
    expanded: false,
    toggle: () => {},
    perform: async (action: string) => {
      performed.push(action);
    },
  };
  const section = connectorsSection({ servers: [], open: false, imessage: view }, actions, translate)!;
  // The person's fold holds: an unconnected iMessage row never forces Connectors open.
  expect(section.open).toBe(false);
  expect(section.meta).toBe(translate("imessage.connect"));
  expect(section.rows[0]!.title).toBe("iMessage");
  actions.run(section.rows[0]!.buttons![0]!.action);
  await Promise.resolve();
  await Promise.resolve();
  expect(performed).toEqual(["connect"]);
  const connected = connectorsSection(
    {
      servers: [],
      open: true,
      imessage: {
        ...view,
        expanded: true,
        data: {
          ...IMESSAGE_INITIAL,
          status: "connected",
          threads: [
            { chat_id: 3, title: "Maya", is_group: false, participants: [] },
            { chat_id: 2, title: "Dinner", is_group: true, participants: [] },
          ],
        },
      },
    },
    new NativeInfoActions(),
    translate,
  )!;
  expect(connected.rows.filter((row) => row.id.startsWith("imessage:thread:")).map((row) => row.title)).toEqual([
    "Maya",
    "Dinner",
  ]);
});
