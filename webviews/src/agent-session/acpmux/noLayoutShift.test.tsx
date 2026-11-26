// The agent pane's host line never moves the content (Leo, 2026-11-21: "stop layout shifting"): the same
// in-flow skeleton while connected, reconnecting before and past the 10 s bound, restoring and failed with
// Retry. test/support/noLayoutShift.ts is the check; bench/host-line-shift.bench.ts
// measures the same states in Chromium. The last test is the control: the line as it was drawn before (a row in
// flow) is caught by the same check.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { CONNECTION_QUIET_MS } from "../../ui/lasting";
import { HostLineSlot, HostRecoveringLine, HostUnavailableLine } from "./HostError";
import { settleReact } from "../../../test/support/domTeardown";
import {
  cssRules,
  drawStates,
  expectOutOfFlow,
  expectSameFlow,
  flowSignature,
  loadStyles,
} from "../../../test/support/noLayoutShift";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><head></head><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
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
  loadStyles(
    dom,
    cssRules(readFileSync(new URL("./styles.css", import.meta.url), "utf8"), /acpmux-host-(slot|chip|line)/),
  );
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

const rows = (
  <>
    <p className="row">first</p>
    <p className="row">second</p>
  </>
);

/// The dock as App.tsx draws it: the chat's rows, the host line's slot, the composer.
function dock(line: React.ReactNode, slotted = true) {
  return (
    <div className="acpmux-dock">
      {rows}
      {slotted ? <HostLineSlot>{line}</HostLineSlot> : line}
      <div className="acpmux-composer" />
    </div>
  );
}

const LONG = 12_000;

const draws = (container: HTMLElement) => {
  root ??= createRoot(container);
  return (line: React.ReactNode, slotted = true) => act(async () => root!.render(dock(line, slotted)));
};

test("the host line moves nothing in any state: connected, reconnecting, restoring, waiting, failed", async () => {
  const container = installDom();
  const draw = draws(container);
  const signature = await drawStates(container, {
    connected: () => draw(<HostRecoveringLine />),
    "dropped, reconnect in flight": () => draw(<HostRecoveringLine now={LONG} />),
    "link down": () => draw(<HostRecoveringLine linkDown now={LONG} />),
    "link down, dot": () => draw(<HostRecoveringLine linkDown now={LONG} variant="dot" />),
    "link down, corner": () => draw(<HostRecoveringLine linkDown now={LONG} variant="corner" />),
    restoring: () => draw(<HostRecoveringLine linkDown restoring={{ waitedMs: LONG, at: 0 }} now={0} />),
    "failed, with Retry": () =>
      draw(<HostUnavailableLine message="Update cmux." selfRetrying={false} onRetry={() => undefined} />),
    "failed, self-retrying": () => draw(<HostUnavailableLine message="Can't connect." />),
    "failed, Restart and Details": () =>
      draw(<HostUnavailableLine message="Another acpmux." detail="why" onRestart={() => undefined} />),
  });
  expectSameFlow(signature);
});

test("nothing shows while the link is down, and the restore's chip is out of flow", async () => {
  const container = installDom();
  const draw = draws(container);
  await draw(<HostRecoveringLine now={LONG} />);
  expect(container.querySelector(".acpmux-host-chip, .acpmux-host-line")).toBeNull();
  await draw(<HostRecoveringLine linkDown now={0} />);
  expect(container.querySelector(".acpmux-host-chip, .acpmux-host-line")).toBeNull();
  await draw(<HostRecoveringLine linkDown restoring={{ waitedMs: 0, at: 0 }} now={0} />);
  expect(container.querySelector(".acpmux-host-chip, .acpmux-host-line")).toBeNull();
  await draw(<HostRecoveringLine linkDown restoring={{ waitedMs: 0, at: 0 }} now={CONNECTION_QUIET_MS} />);
  const chip = container.querySelector(".acpmux-host-chip")!;
  expect(chip.textContent).toContain("Restoring sessions…");
  expectOutOfFlow(chip);
  expect(container.querySelector(".acpmux-host-line")).toBeNull();
});

test("the failure's buttons stay, out of flow", async () => {
  const container = installDom();
  const draw = draws(container);
  await draw(<HostUnavailableLine message="Update cmux." selfRetrying={false} onRetry={() => undefined} />);
  expect(container.querySelector("button")?.textContent).toBe("Retry");
  expectOutOfFlow(container.querySelector(".acpmux-host-line-group")!);
});

test("control: the line drawn as a row in flow is caught", async () => {
  const container = installDom();
  const draw = draws(container);
  const signature = await drawStates(container, {
    connected: () => draw(null, false),
    reconnecting: () =>
      draw(
        <output className="acpmux-host-line">
          <p className="acpmux-host-line-message">Reconnecting…</p>
        </output>,
        false,
      ),
  });
  expect(() => expectSameFlow(signature)).toThrow(/layout shift: state "reconnecting"/);
  expect(flowSignature(container).length).toBeGreaterThan(3);
});
