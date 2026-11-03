// The MCP connect card (plans/cmux-next/mcp-connect-DESIGN.md): Connect sends the person's scope;
// a key server's field empties as it sends and gets the key back when the server refused it; the
// call card's three buttons answer once, always, or decline.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { McpCallCard, McpConnectCard, type McpConnectActions } from "./McpConnectCard";
import type { AcpmuxMcpConnectAsk } from "./model";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const ask = (extra: Partial<AcpmuxMcpConnectAsk> = {}): AcpmuxMcpConnectAsk => ({
  requestId: "r-1",
  title: "Linear",
  publisher: "linear.app",
  verified: true,
  target: "https://mcp.linear.app/mcp",
  auth: "oauth",
  reason: "file the bug",
  proposedScope: "chief",
  phase: "ask",
  ...extra,
});

const recorder = () => {
  const calls: unknown[][] = [];
  const actions: McpConnectActions = {
    answer: (...args) => void calls.push(["answer", ...args]),
    signIn: (...args) => void calls.push(["signIn", ...args]),
    setKey: async (...args) => {
      calls.push(["setKey", ...args]);
      return args[1] === "good-key";
    },
    dismiss: () => void calls.push(["dismiss"]),
  };
  return { calls, actions };
};

async function render(node: React.ReactNode) {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

const click = async (button: Element) =>
  act(async () => void button.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true })));

test("Connect answers with the scope the person picked; the card shows the exact address", async () => {
  const { calls, actions } = recorder();
  const container = await render(<McpConnectCard ask={ask()} agent="Claude" actions={actions} />);
  expect(container.textContent).toContain("https://mcp.linear.app/mcp");
  const select = container.querySelector("select")!;
  expect(select.value).toBe("chief");
  await act(async () => {
    select.value = "chat";
    select.dispatchEvent(new dom!.window.Event("change", { bubbles: true }));
  });
  const [connect] = [...container.querySelectorAll("button")];
  await click(connect!);
  expect(calls).toEqual([["answer", true, "chat"]]);
});

test("a key server's field empties as it sends and gets a refused key back", async () => {
  const { calls, actions } = recorder();
  const container = await render(
    <McpConnectCard
      ask={ask({ phase: "key", connectionId: "mcp_0123456789abcdef" })}
      agent="Claude"
      actions={actions}
    />,
  );
  const field = container.querySelector<HTMLInputElement>("input[type=password]")!;
  const type = async (value: string) =>
    act(async () => {
      const set = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
      set.call(field, value);
      field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
    });
  const submit = async () =>
    act(async () => {
      container
        .querySelector("form")!
        .dispatchEvent(new dom!.window.Event("submit", { bubbles: true, cancelable: true }));
    });
  await type("bad-key");
  await submit();
  await act(async () => {});
  expect(field.value).toBe("bad-key");
  expect(field.getAttribute("aria-invalid")).toBe("true");
  await type("good-key");
  await submit();
  await act(async () => {});
  expect(field.value).toBe("");
  expect(calls).toEqual([
    ["setKey", "mcp_0123456789abcdef", "bad-key"],
    ["setKey", "mcp_0123456789abcdef", "good-key"],
  ]);
  expect(container.textContent).not.toContain("good-key");
});

test("an OAuth server's card offers Sign in for its kept connection", async () => {
  const { calls, actions } = recorder();
  const container = await render(
    <McpConnectCard
      ask={ask({ phase: "signIn", connectionId: "mcp_0123456789abcdef" })}
      agent="Claude"
      actions={actions}
    />,
  );
  await click(container.querySelector("button")!);
  expect(calls).toEqual([["signIn", "mcp_0123456789abcdef"]]);
});

test("the call card answers once, always, or declines", async () => {
  const answers: [boolean, boolean][] = [];
  const container = await render(
    <McpCallCard
      ask={{ requestId: "c-1", title: "Linear", tool: "create_issue", kind: "write", arguments: '{"title":"x"}' }}
      onAnswer={(approve, always) => void answers.push([approve, always])}
    />,
  );
  expect(container.textContent).toContain('{"title":"x"}');
  for (const button of container.querySelectorAll("button")) await click(button);
  expect(answers).toEqual([
    [true, false],
    [true, true],
    [false, false],
  ]);
});
