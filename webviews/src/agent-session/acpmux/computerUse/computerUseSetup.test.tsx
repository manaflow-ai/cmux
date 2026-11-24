// l10n-allow-file: test fixtures.
// A Computer Use call macOS refused for a missing permission offers Set Up Computer Use under it; any
// other call, or another failure, offers nothing. The button runs the app's setup action on a click.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../../test/support/domTeardown";
import { ComputerUseSetupCard } from "./ComputerUseSetupCard";
import { COMPUTER_USE_SETUP_ACTION, computerUseSetupFor } from "./computerUseSetup";

type Tool = NonNullable<Parameters<typeof computerUseSetupFor>[0]>;
const tool = (output: string, title = "cu_click"): Tool => ({ id: "t1", title, output }) as unknown as Tool;
const refused = JSON.stringify({
  error: "the screen_capture permission is not granted. Computer Use needs the Screen Recording permission",
  code: "permission_missing",
  permission: "screen_capture",
  setup: "cmux computer-use setup",
  setup_action: "palette.computerUse.setup",
});

test("a permission_missing result names its permission; others offer nothing", () => {
  expect(computerUseSetupFor(tool(refused))).toBe("screen_capture");
  // Under any tool name (cmux_exec, the MCP server's own names): the result decides.
  expect(computerUseSetupFor(tool(`Error: ${refused}`, "mcp__cmux__cu_screenshot"))).toBe("screen_capture");
  expect(computerUseSetupFor(tool(JSON.stringify({ error: "nope", code: "app_denied" })))).toBeUndefined();
  // A result that only mentions the code (no setup action from the engine) is not one.
  expect(computerUseSetupFor(tool(JSON.stringify({ code: "permission_missing" })))).toBeUndefined();
  expect(computerUseSetupFor(tool("permission_missing in a shell log, not JSON"))).toBeUndefined();
  expect(computerUseSetupFor(undefined)).toBeUndefined();
});

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
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

test("Set Up Computer Use runs the app's setup action on a click", async () => {
  const host = installDom();
  const calls: Array<[string, unknown]> = [];
  const request = <T,>(method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    return Promise.resolve({} as T);
  };
  root = createRoot(host);
  await act(async () => root!.render(<ComputerUseSetupCard request={request} />));
  expect(host.textContent).toContain("Computer Use needs a macOS permission");
  const button = host.querySelector<HTMLButtonElement>(`[data-action="${COMPUTER_USE_SETUP_ACTION}"]`)!;
  expect(button.textContent).toBe("Set Up Computer Use");
  await act(async () => button.click());
  expect(calls).toEqual([["action.run", { id: "palette.computerUse.setup" }]]);
});
