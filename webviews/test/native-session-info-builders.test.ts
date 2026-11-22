// l10n-allow-file: assertions use the localized builder output, not shipped copy.
import { expect, test } from "bun:test";
import { translate, type Translate } from "../src/agent-session/acpmux/i18n";
import { NativeInfoActions } from "../src/agent-session/acpmux/session-info/native/model";
import { usageSection } from "../src/agent-session/acpmux/session-info/native/usage";
import type { SessionUsageStats } from "../src/agent-session/acpmux/usageStats";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import { connectorsSection } from "../src/agent-session/acpmux/session-info/native/connectors";
import { IMESSAGE_INITIAL, type IMessageView } from "../src/agent-session/acpmux/session-info/imessage";
import { settleReact } from "./support/domTeardown";

const t: Translate = (key, values) => translate(key, values, "en");
const stats = (overrides: Partial<SessionUsageStats> = {}): SessionUsageStats => ({
  autocompact: "unknown",
  updatedAt: 1,
  ...overrides,
});
const session = (
  sessionId: string,
  usageStats: SessionUsageStats,
  extra: Partial<AcpmuxSessionEntry> = {},
): AcpmuxSessionEntry => ({
  sessionId,
  usageStats,
  title: sessionId,
  ...extra,
});

test("usage keeps the token fallback and disabled restart-with-cap affordance", () => {
  const own = stats({ tokens24h: 1200, autocompact: "none" });
  const section = usageSection({ own, sessions: [], open: true }, new NativeInfoActions(), t)!;
  expect(section.meta).toBe(t("sessionInfo.usage.tokens24hValue", { tokens: "1.2K" }));
  const cap = section.rows.find((row) => row.id === "own:cap")!;
  expect(cap.trailing).toBe(t("sessionInfo.usage.noCap"));
  expect(cap.buttons?.[0]?.disabled).toBe(true);
  expect(cap.help).toBe(t("sessionInfo.usage.restartWithCapSoon"));
});

test("usage shows the prompt cache's read share and cost per call, as the web panel does", () => {
  const own = stats({ cacheReadShare24h: 0.981, costPerCallUsd24h: 0.3363 });
  const section = usageSection({ own, sessions: [], open: true }, new NativeInfoActions(), t)!;
  const trailing = (id: string) => section.rows.find((row) => row.id === id)?.trailing;
  expect([trailing("own:cache-read"), trailing("own:call-cost")]).toEqual(["98.1%", "$0.34"]);
});

test("usage preserves harness marks, ranks sessions, and exposes sort and View all actions", async () => {
  const sessions = Array.from({ length: 6 }, (_, index) =>
    session(`s${index}`, stats({ costUsd24h: index + 1, contextTokens: (index + 1) * 100 }), {
      harness: index === 5 ? "claude" : undefined,
      host: index === 0 ? "cmux" : undefined,
    }),
  );
  let nextSort: string | undefined;
  let expanded: boolean | undefined;
  const section = usageSection(
    {
      sessions,
      open: true,
      sort: "cost",
      onSortChange: (sort) => {
        nextSort = sort;
      },
      onExpandedChange: (value) => {
        expanded = value;
      },
    },
    new NativeInfoActions(),
    t,
  )!;
  expect(section.rows.find((row) => row.id === "session:s5")?.trailing).toBe("$6.00");
  expect(section.rows.find((row) => row.id === "session:s5")?.harness).toBe("claude");
  const sort = section.rows.find((row) => row.id === "sort")!;
  expect(sort.buttons).toHaveLength(2);
  const actions = new NativeInfoActions();
  // Rebuild with a shared actions object to exercise the page-owned callbacks.
  const rebuilt = usageSection(
    {
      sessions,
      open: true,
      sort: "cost",
      onSortChange: (value) => {
        nextSort = value;
      },
      onExpandedChange: (value) => {
        expanded = value;
      },
    },
    actions,
    t,
  )!;
  expect(actions.run(rebuilt.rows.find((row) => row.id === "sort")!.buttons![1]!.action)).toBe(true);
  await Promise.resolve();
  expect(nextSort).toBe("context");
  expect(rebuilt.more).toBeDefined();
  expect(actions.run(rebuilt.more!.action)).toBe(true);
  await Promise.resolve();
  expect(expanded).toBe(true);
});

test("a folded usage section stays present without ranking until it opens", () => {
  const sessions = [session("s1", stats({ costUsd24h: 1 }))];
  const section = usageSection({ sessions, hasSessionUsage: true, open: false }, new NativeInfoActions(), t)!;
  expect(section).toBeDefined();
  expect(section.rows).toEqual([]);
});

const imessageView = (status: IMessageView["data"]["status"] = "not_connected"): IMessageView => ({
  data: { ...IMESSAGE_INITIAL, status },
  busy: false,
  expanded: false,
  toggle: () => {},
  perform: async () => {},
});

test("native Connectors honors a manual fold throughout iMessage permission steps", () => {
  for (const status of ["not_connected", "needs_full_disk_access", "needs_automation", "connected"] as const) {
    const section = connectorsSection(
      { servers: [], open: false, imessage: imessageView(status) },
      new NativeInfoActions(),
      t,
    )!;
    expect(section.open).toBe(false);
    expect(section.rows[0]!.title).toBe("iMessage");
    expect(
      connectorsSection({ servers: [], open: true, imessage: imessageView(status) }, new NativeInfoActions(), t)!.open,
    ).toBe(true);
  }
});

test("native Connectors retains MCP counts beside every iMessage state", () => {
  for (const status of ["not_connected", "needs_full_disk_access", "needs_automation", "connected"] as const) {
    const imessage = imessageView(status);
    const connected = connectorsSection(
      { servers: [{ name: "github", status: "connected" }], open: false, imessage },
      new NativeInfoActions(),
      t,
    )!;
    expect(connected.meta).toBe(t("sessionInfo.connectors.loaded", { count: 1 }));
    const failed = connectorsSection(
      {
        servers: [
          { name: "github", status: "connected" },
          { name: "linear", status: "failed" },
        ],
        open: false,
        imessage,
      },
      new NativeInfoActions(),
      t,
    )!;
    expect(failed.meta).toBe(t("sessionInfo.connectors.reconnect", { count: 1 }));
    const pending = connectorsSection(
      { servers: [{ name: "github", status: "pending" }], open: false, imessage },
      new NativeInfoActions(),
      t,
    )!;
    expect(pending.meta).toBe(t("sessionInfo.connectors.connecting", { count: 1 }));
  }
  expect(
    connectorsSection({ servers: [], open: false, imessage: imessageView() }, new NativeInfoActions(), t)!.meta,
  ).toBe(t("imessage.connect"));
  expect(
    connectorsSection({ servers: [], open: false, imessage: imessageView("connected") }, new NativeInfoActions(), t)!
      .meta,
  ).toBe(t("rail.connected", { count: 1 }));
});

test("native iMessage reveals Connect once and keeps the person's fold across refreshes and remounts", async () => {
  const { JSDOM } = await import("jsdom");
  const { act, createElement } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { setNativeHost } = await import("../src/agent-session/acpmux/native");
  const { resetSessionInfoState, sessionInfoState } =
    await import("../src/agent-session/acpmux/session-info/sessionInfoState");
  const { runNativeSessionInfoAction, setNativeSessionInfoHost } =
    await import("../src/agent-session/acpmux/session-info/native/host");
  const dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  Object.defineProperty(dom.window.navigator, "platform", { value: "MacIntel" });
  const scope = globalThis as Record<string, unknown>;
  const frames = new Map<number, FrameRequestCallback>();
  let frameId = 0;
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    localStorage: dom.window.localStorage,
    requestAnimationFrame: (callback: FrameRequestCallback) => {
      frames.set(++frameId, callback);
      return frameId;
    },
    cancelAnimationFrame: (id: number) => frames.delete(id),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, replacements);
  const { NativeSessionInfo } = await import("../src/agent-session/acpmux/session-info/native/NativeSessionInfo");
  const root = createRoot(dom.window.document.getElementById("root")!);
  let status: IMessageView["data"]["status"] = "not_connected";
  setNativeHost(async (method) => (method === "imessage.status" ? { ...IMESSAGE_INITIAL, status } : {}));
  resetSessionInfoState();
  const renderPanel = () =>
    root.render(
      createElement(NativeSessionInfo, {
        shown: true,
        width: 320,
        top: 0,
        side: 0,
        label: "Session Info",
        links: [],
        artifacts: 0,
        documents: [],
        rows: [],
        agents: [],
        waiting: new Set<string>(),
        statuses: {},
        processes: [],
        listed: true,
        transcriptTasks: [],
        sessions: [],
        workflows: [],
      }),
    );
  try {
    await act(async () => renderPanel());
    expect(sessionInfoState().sections.connectors).toBe(true);
    await act(async () => runNativeSessionInfoAction("fold:connectors:0"));
    expect(sessionInfoState().sections.connectors).toBe(false);
    for (const next of ["needs_full_disk_access", "needs_automation", "connected", "not_connected"] as const) {
      status = next;
      await act(async () => dom.window.dispatchEvent(new dom.window.Event("cmux-imessage-changed")));
      expect(sessionInfoState().sections.connectors).toBe(false);
    }
    await act(async () => root.render(null));
    await act(async () => renderPanel());
    expect(sessionInfoState().sections.connectors).toBe(false);
    status = "needs_full_disk_access";
    await act(async () => dom.window.dispatchEvent(new dom.window.Event("cmux-imessage-changed")));
    expect(sessionInfoState().sections.connectors).toBe(false);
  } finally {
    await act(async () => root.unmount());
    setNativeHost(undefined);
    setNativeSessionInfoHost(false);
    resetSessionInfoState();
    frames.clear();
    await settleReact();
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  }
});
