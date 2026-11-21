// l10n-allow-file: test fixtures, not shipped UI.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../../test/support/domTeardown";
import { translate } from "../i18n";
import { setNativeHost, type postNative } from "../native";
import { GitHubConnectCard } from "./GitHubConnectCard";
import { GitHubConnectRecovery } from "./GitHubConnectRecovery";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

async function render(request: typeof postNative, content?: ReactNode) {
  dom = new JSDOM("<!doctype html><html><body><main></main></body></html>", { url: "http://localhost/" });
  const values = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(values)) saved.set(key, scope[key]);
  saved.set("cmuxExperiments", scope.cmuxExperiments);
  Object.assign(scope, values);
  const container = dom.window.document.querySelector("main")!;
  await act(async () => {
    root = createRoot(container);
    root.render(content ?? <GitHubConnectCard request={request} />);
  });
  return container;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  setNativeHost(undefined);
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("the real recovery gate renders nothing by default and only acts after opting in and clicking", async () => {
  const calls: string[] = [];
  const request: typeof postNative = async <T,>(method: string) => {
    calls.push(method);
    return { opened: true } as T;
  };
  const tool = {
    id: "github-recovery-gate",
    title: "mcp__github__get_me",
    status: "failed",
    output: JSON.stringify({
      isError: true,
      structuredContent: {
        error: {
          code: "github.not_connected",
          retryable: true,
          connect: { action: "accounts.githubConnect" },
        },
      },
    }),
  };
  const card = await render(request, <GitHubConnectRecovery tool={tool} />);
  setNativeHost(request);
  expect(card.textContent).toBe("");
  expect(calls).toEqual([]);
  globalThis.cmuxExperiments = { "github-connect-inline": "on" };
  await act(async () => {
    root!.render(<GitHubConnectRecovery tool={tool} />);
  });
  expect(card.querySelectorAll("button").length).toBe(1);
  expect(calls).toEqual([]);
  await act(async () => {
    card.querySelector("button")!.click();
  });
  expect(calls).toEqual(["github.connect"]);
});

test("one click launches the supported bridge; pending clicks cannot duplicate it", async () => {
  const calls: unknown[] = [];
  let resolve!: (value: unknown) => void;
  const pending = new Promise((done) => {
    resolve = done;
  });
  const request: typeof postNative = <T,>(method: string, params?: Record<string, unknown>) => {
    calls.push({ method, params });
    return pending as Promise<T>;
  };
  const card = await render(request);
  expect(calls).toEqual([]);
  const button = card.querySelector("button")!;
  await act(async () => {
    button.click();
    button.click();
  });
  expect(calls).toEqual([{ method: "github.connect", params: {} }]);
  expect(button.disabled).toBe(true);
  await act(async () => {
    resolve({ opened: true });
  });
  expect(button.disabled).toBe(false);
  expect(card.textContent).toBe(translate("cloudRepository.connect"));
  expect(card.querySelector("[role=alert]")).toBeNull();
});

test("a rejected launch says it failed and permits another attempt", async () => {
  let attempts = 0;
  const request: typeof postNative = <T,>() => {
    attempts += 1;
    return attempts === 1 ? Promise.reject(new Error("github.signed_out")) : Promise.resolve({ opened: false } as T);
  };
  const card = await render(request);
  const button = card.querySelector("button")!;
  await act(async () => {
    button.click();
  });
  expect(card.querySelector("[role=alert]")?.textContent).toBe(translate("composer.githubConnectFailed"));
  expect(button.disabled).toBe(false);
  await act(async () => {
    button.click();
  });
  expect(attempts).toBe(2);
  expect(card.querySelector("[role=alert]")).toBeNull();
});
