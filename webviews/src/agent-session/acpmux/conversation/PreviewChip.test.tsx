// l10n-allow-file: test fixture commands and addresses, not shipped UI.
// A background command that serves a page shows it on its own row while it runs: the globe and
// `localhost:5173` at the row's edge, from acpmux's `preview` on the process (hub/processes.rs).
// A click opens the page and never opens the row; the chip leaves when the process ends. The
// running turn's line names the newest one as a part after its counts.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../i18n";
import type { AcpmuxActivity, AcpmuxBackgroundState } from "../model";
import { mergeProcess, processesOf, serverOf, serverUrl, type ProcessPreview } from "../session-info/processes";
import { resetTranscriptDisclosure } from "./transcriptDisclosureModel";
import { CommandRow } from "./CommandRow";
import { ToolRow } from "./ToolRow";
import { PreviewChipsContext, previewAddress, previewsOf, type PreviewChips } from "./previewChipModel";
import { workingParts } from "./workingForModel";
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
    if (!saved.has(key)) saved.set(key, scope[key]);
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
  resetTranscriptDisclosure();
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

const STARTED = Date.UTC(2026, 10, 8, 10, 0, 0);
const VITE: ProcessPreview = { url: "http://localhost:5173/", port: 5173 };
const call = (background: AcpmuxBackgroundState): AcpmuxActivity => ({
  kind: "tool",
  text: "npm run dev",
  tool: {
    id: "bg1",
    title: "npm run dev",
    kind: "execute",
    status: "completed",
    command: "npm run dev",
    startedAt: STARTED,
    endedAt: STARTED + 200,
    background,
  },
});

function chips(opened: ProcessPreview[]): PreviewChips {
  return { byTool: new Map([["bg1", VITE]]), latest: VITE, open: (preview) => opened.push(preview) };
}

for (const [name, Row] of [
  ["CommandRow", CommandRow],
  ["ToolRow", ToolRow],
] as const) {
  test(`${name}: a running server's page is a chip at the row's edge; a click opens it, not the row`, async () => {
    const opened: ProcessPreview[] = [];
    const container = await render(
      <PreviewChipsContext.Provider value={chips(opened)}>
        <Row item={call({ state: "running" })} />
      </PreviewChipsContext.Provider>,
    );
    const chip = container.querySelector<HTMLElement>(".cv-preview-chip")!;
    expect(chip.textContent).toBe("localhost:5173");
    expect(chip.getAttribute("role")).toBe("link");
    expect(chip.getAttribute("aria-label")).toBe(translate("sessionInfo.servers.open", { url: VITE.url }));
    expect(chip.closest(".cv-command__meta")).not.toBeNull();
    const row = chip.closest("button")!;
    const before = row.getAttribute("aria-expanded");
    await act(async () => chip.click());
    expect(opened).toEqual([VITE]);
    expect(row.getAttribute("aria-expanded")).toBe(before);
    await act(async () => {
      chip.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    expect(opened).toEqual([VITE, VITE]);
  });

  test(`${name}: no chip once the command ended, nor for a command that serves no page`, async () => {
    const ended = await render(
      <PreviewChipsContext.Provider value={chips([])}>
        <Row item={call({ state: "completed", endedAt: STARTED + 5_000 })} />
      </PreviewChipsContext.Provider>,
    );
    expect(ended.querySelector(".cv-preview-chip")).toBeNull();
    await act(async () => root!.unmount());
    root = undefined;
    const none = await render(<Row item={call({ state: "running" })} />);
    expect(none.querySelector(".cv-preview-chip")).toBeNull();
  });
}

const wire = (state: string, preview?: unknown, extra: Record<string, unknown> = {}) => ({
  id: "s1/t1",
  sessionId: "s1",
  toolCallId: "bg1",
  command: "npm run dev",
  startedAt: STARTED,
  state,
  ...(preview === undefined ? {} : { preview }),
  ...extra,
});

test("the registry keeps a running process's loopback page, and drops it once it ends or names another host", () => {
  expect(processesOf({ processes: [wire("running", VITE)] }, "s1")[0]!.preview).toEqual(VITE);
  expect(processesOf({ processes: [wire("exited", VITE)] }, "s1")[0]!.preview).toBeUndefined();
  for (const bad of [
    { url: "http://example.com:5173/", port: 5173 },
    { url: "file:///etc/passwd", port: 1 },
    { url: "http://localhost:5173/", port: 0 },
    { url: "not a url", port: 5173 },
    "http://localhost:5173/",
  ])
    expect(processesOf({ processes: [wire("running", bad)] }, "s1")[0]!.preview).toBeUndefined();
  const running = processesOf({ processes: [wire("running", VITE)] }, "s1");
  const ended = mergeProcess(running, wire("exited", undefined, { endedAt: STARTED + 1 }), "s1");
  expect(ended[0]!.preview).toBeUndefined();
});

test("a process acpmux saw serve a page is a server at that port, whatever its command", () => {
  const [process] = processesOf(
    { processes: [wire("running", { url: "http://localhost:4000/", port: 4000 }, { command: "./bin/start" })] },
    "s1",
  );
  expect(serverOf(process!)?.ports).toEqual([4000]);
  const [named] = processesOf({ processes: [wire("running", VITE, { command: "vite --port 5173" })] }, "s1");
  expect(serverOf(named!)?.ports).toEqual([5173]);
});

test("previewsOf maps running pages by call and names the newest", () => {
  const processes = processesOf(
    {
      processes: [
        wire("running", VITE),
        wire(
          "running",
          { url: "http://127.0.0.1:3000/admin", port: 3000 },
          { id: "s1/t2", toolCallId: "bg2", startedAt: STARTED + 9 },
        ),
        wire("exited", undefined, { id: "s1/t3", toolCallId: "bg3" }),
      ],
    },
    "s1",
  );
  const { byTool, latest } = previewsOf(processes);
  expect([...byTool.keys()]).toEqual(["bg1", "bg2"]);
  expect(latest?.port).toBe(3000);
  expect(previewsOf([]).latest).toBeUndefined();
});

test("the address reads host and port, with a path only when it is not the root", () => {
  expect(previewAddress("http://localhost:5173/")).toBe("localhost:5173");
  expect(previewAddress("http://127.0.0.1:3000/admin/")).toBe("127.0.0.1:3000/admin");
});

test("the running line names the newest page after its counts, and opens it", () => {
  let opened = 0;
  const parts = workingParts(translate, {
    agents: 0,
    commands: 1,
    sessions: 0,
    openAgents: () => {},
    openCommands: () => {},
    openSessions: () => {},
    preview: { url: VITE.url, open: () => (opened += 1) },
  });
  expect(parts.map((part) => [part.key, part.label])).toEqual([
    ["commands", translate("turn.working.commands", { n: 1 })],
    ["preview", "localhost:5173"],
  ]);
  parts[1]!.open();
  expect(opened).toBe(1);
});

test("Session Info opens the page acpmux found at its port, scheme and path kept", () => {
  const [process] = processesOf(
    {
      processes: [
        wire("running", { url: "https://localhost:8443/app", port: 8443 }, { command: "./serve --port 9000" }),
      ],
    },
    "s1",
  );
  const server = serverOf(process!)!;
  expect(server.ports).toEqual([8443, 9000]);
  expect(server.ports.map((port) => serverUrl(server, port))).toEqual([
    "https://localhost:8443/app",
    "http://localhost:9000",
  ]);
});
