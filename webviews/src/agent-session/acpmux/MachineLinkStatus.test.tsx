import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { MachineLinkStatus } from "./MachineLinkStatus";
import type { PeerLink } from "./peerLink";
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

test("automatic connecting and reconnecting keep the plain dot even beyond the duration bound", async () => {
  const container = installDom();
  root = createRoot(container);
  for (const reconnecting of [undefined, true] as const) {
    for (const quietMs of [10_000, 0]) {
      await act(async () => {
        root!.render(
          <MachineLinkStatus
            link={{ machine: "remote", link: "connecting", reconnecting }}
            quietMs={quietMs}
            onReconnect={() => undefined}
          />,
        );
      });
      expect(container.querySelector("[data-quiet]")).not.toBeNull();
      expect(container.querySelector("[data-said]")).toBeNull();
      expect(container.querySelector(".cv-spinner")).toBeNull();
      expect(container.querySelector("button")).toBeNull();
      expect(container.querySelector("output")?.getAttribute("aria-label")).toBe("remote");
    }
  }
});

test("an offline link stays quiet before the bound and offers Reconnect once it persists", async () => {
  const container = installDom();
  root = createRoot(container);
  const link: PeerLink = { machine: "remote", link: "offline" };
  let reconnected = 0;
  const render = (quietMs: number) =>
    act(async () => {
      root!.render(
        <MachineLinkStatus
          link={link}
          quietMs={quietMs}
          onReconnect={() => {
            reconnected++;
          }}
        />,
      );
    });
  await render(10_000);
  expect(container.querySelector("[data-said]")).toBeNull();
  expect(container.querySelector("button")).toBeNull();
  await render(0);
  expect(container.querySelector("[data-said]")).not.toBeNull();
  expect(container.querySelector("button")?.textContent).toBe("Reconnect");
  await act(async () => container.querySelector("button")!.click());
  expect(reconnected).toBe(1);
});

test("sign-in and update failures need a person, so they are said at once with their instruction", async () => {
  const container = installDom();
  root = createRoot(container);
  for (const why of ["authFailed", "updateRequired"] as const) {
    const link: PeerLink = { machine: "remote", link: "offline", stuck: true, why };
    await act(async () => root!.render(<MachineLinkStatus link={link} quietMs={10_000} />));
    expect(container.querySelector("[data-said]")).not.toBeNull();
    expect(container.textContent).toContain(why === "authFailed" ? "Sign-in needed" : "Update required");
  }
});
