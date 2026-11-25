// The sudo card (request_elevation) shows the exact command sudo runs, sends the password only
// through onAnswer, empties its field as it sends, and denies with no value.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { commandLine, ElevationCard } from "./ElevationCard";
import { settleReact } from "../../../test/support/domTeardown";

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
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const ask = {
  secretId: "e-1",
  name: "sudo",
  reason: "See which process writes to disk",
  elevation: { argv: ["fs_usage", "-w", "-t", "10", "it's"], host: "leos-mbp", timeoutSecs: 20 },
};

async function render(onAnswer: (value?: string) => Promise<unknown> | void) {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<ElevationCard ask={ask} agent="Claude" onAnswer={onAnswer} />);
  });
  return container;
}

async function approve(container: HTMLElement, password: string) {
  const field = container.querySelector<HTMLInputElement>("input")!;
  await act(async () => {
    const set = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
    set.call(field, password);
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  await act(async () => {
    container
      .querySelector("form")!
      .dispatchEvent(new dom!.window.Event("submit", { bubbles: true, cancelable: true }));
  });
  await act(async () => {});
  return field;
}

test("the card shows the exact command, host and reason, and a password field", async () => {
  const container = await render(() => undefined);
  expect(container.querySelector("code")!.textContent).toBe(`sudo fs_usage -w -t 10 'it'\\''s'`);
  expect(container.textContent).toContain("leos-mbp");
  expect(container.textContent).toContain("See which process writes to disk");
  expect(container.querySelector("input")!.type).toBe("password");
});

test("approve sends the password once, empties the field, and never draws it", async () => {
  const sent: (string | undefined)[] = [];
  const container = await render((value) => {
    sent.push(value);
  });
  const field = await approve(container, "sentinel-pw-3e1");
  expect(sent).toEqual(["sentinel-pw-3e1"]);
  expect(field.value).toBe("");
  expect(container.innerHTML).not.toContain("sentinel-pw-3e1");
});

test("deny answers with no value", async () => {
  const sent: (string | undefined)[] = [];
  const container = await render((value) => {
    sent.push(value);
  });
  const deny = [...container.querySelectorAll("button")].find((b) => b.textContent === "Deny")!;
  await act(async () => deny.click());
  expect(sent).toEqual([undefined]);
});

test("a password that could not be sent stays in the field and marks it", async () => {
  const field = await approve(await render(async () => Promise.reject(new Error("native.not_connected"))), "pw");
  expect(field.value).toBe("pw");
  expect(field.getAttribute("aria-invalid")).toBe("true");
});

test("commandLine quotes only what needs it", () => {
  expect(commandLine(["ls", "-la", "/var/db"])).toBe("sudo ls -la /var/db");
  expect(commandLine(["echo", "a b", ""])).toBe("sudo echo 'a b' ''");
});
