import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const frames: FrameRequestCallback[] = [];
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "IS_REACT_ACT_ENVIRONMENT",
    "requestAnimationFrame",
    "cancelAnimationFrame",
  ].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
  requestAnimationFrame: (callback: FrameRequestCallback) => frames.push(callback),
  cancelAnimationFrame: (handle: number) => {
    frames[handle - 1] = () => {};
  },
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { Inspector, SHOWN_ROWS, exportFileName, sessionRow, visibleRows, wireRow } = await import("./Inspector");
type ExportOutcome = import("./Inspector").ExportOutcome;
const { AcpWireLog } = await import("./wire");
type Snapshot = import("./model").AcpmuxSnapshot;
type EventRecord = import("./direct").EventRecord;

const snapshot: Snapshot = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "connected",
  sessionId: "0123456789abcdef",
  summary: { sessionId: "0123456789abcdef", status: "idle" },
  isWorking: false,
  queue: [],
  catalog: [],
  canLoadOlder: false,
};
const flushFrames = () =>
  act(async () => {
    for (const callback of frames.splice(0)) callback(0);
  });

function mount(wire: InstanceType<typeof AcpWireLog>, events: EventRecord[] = [], onExport?: (text: string, suggestedName: string) => Promise<ExportOutcome>) {
  const root = createRoot(dom.window.document.getElementById("root")!);
  let closed = 0;
  const render = () =>
    act(async () =>
      root.render(
        createElement(Inspector, {
          snapshot,
          wire,
          sessionEvents: () => events,
          onExport,
          onClose: () => {
            closed += 1;
          },
        }),
      ),
    );
  const query = (selector: string) => [...dom.window.document.querySelectorAll(selector)];
  const click = (element: Element) =>
    act(async () => {
      element.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
    });
  return { render, query, click, closed: () => closed, unmount: () => act(async () => root.unmount()) };
}

describe("ACP inspector rows", () => {
  test("a wire reply shows its method, id and latency, and its body is formatted JSON", () => {
    const wire = new AcpWireLog(
      () => 0,
      () => 0,
    );
    wire.sent('{"id":4,"method":"session/prompt"}', "session/prompt", 4);
    wire.received('{"id":4,"result":{"stopReason":"end_turn"}}');
    const reply = wireRow(wire.entries()[1]!);
    expect(reply).toMatchObject({ kind: "response", name: "session/prompt #4", latencyMs: 0 });
    expect(reply.body).toBe(JSON.stringify({ id: 4, result: { stopReason: "end_turn" } }, null, 2));
  });

  test("a journal event is named by its method and update kind", () => {
    const row = sessionRow({
      seq: 9,
      at: 0,
      dir: "in",
      kind: "notification",
      msg: { method: "session/update", params: { update: { sessionUpdate: "agent_message_chunk" } } },
    });
    expect(row.name).toBe("session/update agent_message_chunk · seq 9");
  });

  test("the filter matches names and bodies, and only the newest rows are kept", () => {
    const rows = Array.from({ length: SHOWN_ROWS + 20 }, (_, index) => ({
      key: `${index}`,
      at: 0,
      dir: "in",
      kind: "notification",
      name: index % 2 ? "session/update" : "_acpmux/event",
      body: index === 3 ? "needle" : "",
    }));
    expect(visibleRows(rows, "").length).toBe(SHOWN_ROWS);
    expect(visibleRows(rows, "").at(0)!.key).toBe("20");
    expect(visibleRows(rows, "NEEDLE").map((row) => row.key)).toEqual(["3"]);
    expect(visibleRows(rows, "session/update").length).toBe((SHOWN_ROWS + 20) / 2);
  });
});

describe("ACP inspector panel", () => {
  test("shows the connection, stats and wire rows, and redraws once per frame", async () => {
    const wire = new AcpWireLog(
      () => 0,
      () => 0,
    );
    wire.lifecycle("connected");
    const pane = mount(wire);
    await pane.render();
    expect(pane.query(".acpmux-inspector-row").length).toBe(1);
    expect(pane.query(".acpmux-inspector-state dd").map((dd) => dd.textContent)).toContain("01234567 · idle");

    for (let index = 0; index < 50; index += 1) wire.received(`{"method":"session/update","params":{"n":${index}}}`);
    expect(frames.length).toBe(1);
    expect(pane.query(".acpmux-inspector-row").length).toBe(1);
    await flushFrames();
    expect(pane.query(".acpmux-inspector-row").length).toBe(51);

    await pane.click(pane.query(".acpmux-inspector-row > button").at(-1)!);
    expect(pane.query(".acpmux-inspector-row pre").map((pre) => pre.textContent)).toEqual([
      JSON.stringify({ method: "session/update", params: { n: 49 } }, null, 2),
    ]);
    await pane.unmount();
    wire.lifecycle("close");
    expect(frames.length).toBe(0);
  });

  test("the Session view lists the client's journal, and Escape closes", async () => {
    const events: EventRecord[] = [
      { seq: 1, at: 0, dir: "out", kind: "request", msg: { method: "session/prompt" } },
      {
        seq: 2,
        at: 0,
        dir: "in",
        kind: "notification",
        msg: { method: "session/update", params: { update: { sessionUpdate: "plan" } } },
      },
    ];
    const pane = mount(
      new AcpWireLog(
        () => 0,
        () => 0,
      ),
      events,
    );
    await pane.render();
    await pane.click(pane.query("button").find((button) => button.textContent === "Session")!);
    expect(pane.query(".acpmux-inspector-name").map((name) => name.textContent)).toEqual([
      "session/prompt · seq 1",
      "session/update plan · seq 2",
    ]);
    await act(async () => {
      dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape" }));
    });
    expect(pane.closed()).toBe(1);
    await pane.unmount();
  });
});

describe("ACP inspector export", () => {
  const copies: string[] = [];
  const document = dom.window.document as unknown as { execCommand(command: string): boolean };
  document.execCommand = (command) => { copies.push(command); return true; };
  const exportWith = async (onExport?: (text: string, suggestedName: string) => Promise<ExportOutcome>) => {
    const wire = new AcpWireLog(() => 0, () => 0);
    wire.lifecycle("connected");
    const pane = mount(wire, [], onExport);
    await pane.render();
    copies.length = 0;
    await pane.click(pane.query("button").find((button) => button.textContent === "Export")!);
    const notice = pane.query("output").map((output) => output.textContent);
    await pane.unmount();
    return notice;
  };

  test("the file name carries the session and the local time", () => {
    expect(exportFileName("0123456789abcdef", new Date(2026, 9, 1, 9, 5, 7))).toBe("acp-01234567-20261001-090507.jsonl");
    expect(exportFileName(undefined, new Date(2026, 0, 2, 3, 4, 5))).toBe("acp-20260102-030405.jsonl");
  });

  test("a saved export says so and copies nothing", async () => {
    const asked: string[] = [];
    expect(await exportWith(async (text, name) => { asked.push(name); expect(text.split("\n")[0]).toContain("\"connection\":\"connected\""); return "saved"; })).toEqual(["Saved"]);
    expect(asked[0]).toMatch(/^acp-01234567-\d{8}-\d{6}\.jsonl$/);
    expect(copies).toEqual([]);
  });

  test("a cancelled save panel shows nothing and copies nothing", async () => {
    expect(await exportWith(async () => "cancelled")).toEqual([]);
    expect(copies).toEqual([]);
  });

  test("a host that cannot save, or fails, falls back to copying", async () => {
    expect(await exportWith(async () => "unavailable")).toEqual(["Copied as JSON Lines"]);
    expect(copies).toEqual(["copy"]);
    expect(await exportWith(() => Promise.reject(new Error("closed")))).toEqual(["Copied as JSON Lines"]);
    expect(await exportWith()).toEqual(["Copied as JSON Lines"]);
  });
});
