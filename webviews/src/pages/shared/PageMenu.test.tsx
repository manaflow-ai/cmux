// A page menu (History's row menu) in the app is the app's standard macOS menu: it hands the rows
// and the pointer to the host, draws nothing in the page, and runs the chosen row.
import { afterEach, expect, test } from "bun:test";
import { act, StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PageMenu } from "./PageMenu";
import { installNativeMenu, type NativeMenuRequest } from "../../ui/nativeMenu";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  // The page-drawn fallback is a Base UI menu, which schedules its transitions on animation frames.
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  const cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame,
    cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  installNativeMenu(null);
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

test("a page menu opens the app's native menu and runs the chosen row", async () => {
  const asked: NativeMenuRequest[] = [];
  const ran: string[] = [];
  let closed = 0;
  installNativeMenu(async (request) => {
    asked.push(request);
    return { picked: "remove" };
  });
  root = createRoot(installDom());
  await act(async () => {
    root!.render(
      <PageMenu
        x={12}
        y={34}
        items={[
          { id: "open", label: "Open", run: () => ran.push("open") },
          { id: "remove", label: "Remove", separatorBefore: true, destructive: true, run: () => ran.push("remove") },
        ]}
        onClose={() => closed++}
      />,
    );
    await Promise.resolve();
  });
  expect(asked).toEqual([
    {
      items: [
        { id: "open", label: "Open" },
        { id: "separator:remove", label: "", separator: true },
        { id: "remove", label: "Remove" },
      ],
      point: { x: 12, y: 34 },
    },
  ]);
  expect(document.querySelector(".page-menu")).toBeNull();
  expect(ran).toEqual(["remove"]);
  expect(closed).toBe(1);
});

test.each([null, { ok: true, value: null }])(
  "an older host's empty native-menu reply falls back to an actionable page menu (%#)",
  async (reply) => {
    const ran: string[] = [];
    let closed = 0;
    installNativeMenu(async () => reply);
    root = createRoot(installDom());
    await act(async () => {
      root!.render(
        <PageMenu
          x={12}
          y={34}
          items={[{ id: "open", label: "Open", run: () => ran.push("open") }]}
          onClose={() => closed++}
        />,
      );
      await Promise.resolve();
    });
    expect(document.querySelector(".page-menu")).not.toBeNull();
    expect(closed).toBe(0);
    expect(ran).toEqual([]);
  },
);

test("a native host cannot activate a disabled page action", async () => {
  const ran: string[] = [];
  let closed = 0;
  installNativeMenu(async () => ({ picked: "remove" }));
  root = createRoot(installDom());
  await act(async () => {
    root!.render(
      <PageMenu
        x={12}
        y={34}
        items={[{ id: "remove", label: "Remove", disabled: true, run: () => ran.push("remove") }]}
        onClose={() => closed++}
      />,
    );
    await Promise.resolve();
  });
  expect(document.querySelector(".page-menu")).toBeNull();
  expect(closed).toBe(1);
  expect(ran).toEqual([]);
});

test("a native reply after this menu unmounts cannot run a stale row action", async () => {
  let reply: (value: unknown) => void = () => {};
  const ran: string[] = [];
  let closed = 0;
  installNativeMenu(() => new Promise<unknown>((resolve) => (reply = resolve)));
  root = createRoot(installDom());
  await act(async () => {
    root!.render(
      <PageMenu
        x={12}
        y={34}
        items={[{ id: "remove", label: "Remove", run: () => ran.push("remove") }]}
        onClose={() => closed++}
      />,
    );
  });
  await act(async () => {
    root!.unmount();
  });
  root = undefined;
  await act(async () => {
    reply({ picked: "remove" });
    await Promise.resolve();
  });
  expect(ran).toEqual([]);
  expect(closed).toBe(0);
});

test("a newer keyed menu keeps its actions when an older native reply finishes later", async () => {
  const pending: Array<(value: unknown) => void> = [];
  const ran: string[] = [];
  let closed = 0;
  installNativeMenu(() => new Promise<unknown>((resolve) => pending.push(resolve)));
  root = createRoot(installDom());
  const renderSession = (session: string) => (
    <PageMenu
      key={session}
      x={session === "old" ? 12 : 50}
      y={34}
      items={[{ id: session, label: session, run: () => ran.push(session) }]}
      onClose={() => closed++}
    />
  );
  await act(async () => {
    root!.render(renderSession("old"));
  });
  await act(async () => {
    root!.render(renderSession("new"));
  });
  expect(pending).toHaveLength(2);
  await act(async () => {
    pending[0]!({ picked: "old" });
    await Promise.resolve();
  });
  expect(ran).toEqual([]);
  expect(closed).toBe(0);
  await act(async () => {
    pending[1]!({ picked: "new" });
    await Promise.resolve();
  });
  expect(ran).toEqual(["new"]);
  expect(closed).toBe(1);
});

test("under StrictMode's double-run effects the menu asks once and still runs the pick", async () => {
  let reply: (value: unknown) => void = () => {};
  let asked = 0;
  const ran: string[] = [];
  let closed = 0;
  installNativeMenu(() => {
    asked++;
    return new Promise<unknown>((resolve) => (reply = resolve));
  });
  root = createRoot(installDom());
  await act(async () => {
    root!.render(
      <StrictMode>
        <PageMenu
          x={12}
          y={34}
          items={[{ id: "remove", label: "Remove", run: () => ran.push("remove") }]}
          onClose={() => closed++}
        />
      </StrictMode>,
    );
  });
  expect(asked).toBe(1);
  await act(async () => {
    reply({ picked: "remove" });
    await Promise.resolve();
  });
  expect(ran).toEqual(["remove"]);
  expect(closed).toBe(1);
});
