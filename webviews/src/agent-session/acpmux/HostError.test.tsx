// A host failure the pane says is one line above the composer with one small action and no
// recovery steps (Leo, 2026-10-29). A chat refused because another binary's acpmux holds this
// app's socket (2026-10-22: with only Retry, which asked the same daemon again) offers Restart acpmux.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { HostError, HostUnavailableLine, HostWaitingLine, waitedText } from "./HostError";
import { hostLineText } from "./hostLine";
import { hostErrorShows } from "./hostRetry";
import { translate } from "./i18n";
import { Notice, NoticeSlot } from "./NoticeSlot";

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

const buttons = (container: HTMLElement) => [...container.querySelectorAll("button")].map((b) => b.textContent);

test("a refusal another binary's acpmux caused is one line whose one action is Restart acpmux", async () => {
  const container = installDom();
  const pressed: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <HostUnavailableLine
        message="acpmux belongs to cmux NIGHTLY, and this build may not use it."
        onRetry={() => pressed.push("retry")}
        onRestart={() => pressed.push("restart")}
      />,
    );
  });
  expect(buttons(container)).toEqual(["Restart acpmux"]);
  expect(container.querySelectorAll("p")).toHaveLength(1);
  expect(container.textContent).not.toContain("starts the one in this app");
  await act(async () => container.querySelector("button")!.click());
  expect(pressed).toEqual(["restart"]);
});

test("a restart in flight holds its button", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <HostUnavailableLine message="refused" onRetry={() => undefined} onRestart={() => undefined} restarting />,
    );
  });
  expect(buttons(container)).toEqual(["Restarting acpmux…"]);
  expect([...container.querySelectorAll("button")].every((b) => b.disabled)).toBe(true);
});

test("a queued Retry holds Restart acpmux until the handshake settles", async () => {
  const container = installDom();
  const pressed: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <HostUnavailableLine
        message="socket closed"
        retrying
        onRetry={() => pressed.push("retry")}
        onRestart={() => pressed.push("restart")}
      />,
    );
  });
  const [restart] = [...container.querySelectorAll<HTMLButtonElement>("button")];
  expect(restart?.textContent).toBe("Restart acpmux");
  expect(restart?.disabled).toBe(true);
  await act(async () => restart?.click());
  expect(pressed).toEqual([]);
});

test("a late failure is its message and Retry, with no recovery steps", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<HostUnavailableLine message="acpmux did not answer in time." onRetry={() => undefined} />);
  });
  expect(buttons(container)).toEqual(["Retry"]);
  expect(container.querySelector('[role="alert"]')).not.toBeNull();
  expect(container.querySelectorAll("p")).toHaveLength(1);
  expect(container.textContent).toBe("acpmux did not answer in time.Retry");
  expect(container.textContent).not.toContain("tries again on its own");
  expect(container.textContent).not.toContain("stays here until");
  expect(container.querySelector(".cv-spinner__arc")).toBeNull();
});

test("a Retry waiting on the attempt in flight says so and holds", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<HostUnavailableLine message="acpmux did not answer in time." onRetry={() => undefined} retrying />);
  });
  expect(buttons(container)).toEqual(["Retrying…"]);
  expect(container.querySelector("button")!.disabled).toBe(true);
});

test("a folder harness keeps its card with its own hint and action", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <HostError
        message="Claude Code is not enabled."
        hint={null}
        action="Enable Claude Code"
        onRetry={() => undefined}
      />,
    );
  });
  expect(container.querySelector(".acpmux-host-error-card")).not.toBeNull();
  expect(buttons(container)).toEqual(["Enable Claude Code"]);
  expect(container.querySelectorAll("p")).toHaveLength(1);
});

// Leo, 2026-10-30, on a red card while a chat's machine was only reconnecting: "it was literally
// just loading ... that's not the fucking right time to be showing that kind of fucking message."
// Rendered as App.tsx renders the host line: its Notice shows only when hostErrorShows says so,
// worded by hostLineText.
const LEOS =
  "peer_unreachable: <host> (reconnecting, last seen 10s ago: WebSocket protocol error: Handshake not finished); the request was not sent; run `acpmux host ls` and retry after the peer reconnects";

function PaneHostLine({ error, failingForMs }: { error: unknown; failingForMs: number }) {
  const message = error instanceof Error ? error.message : String(error);
  const hostLine = hostLineText(error, message, translate);
  return (
    <NoticeSlot>
      <Notice id="host-error" tier="error" when={hostErrorShows(error, failingForMs)}>
        <HostUnavailableLine message={hostLine.line} detail={hostLine.detail} onRetry={() => undefined} />
      </Notice>
    </NoticeSlot>
  );
}

test("a reconnecting or slow peer renders no card, no line and no Retry", async () => {
  const container = installDom();
  root = createRoot(container);
  for (const failingForMs of [0, 10_000, 60_000]) {
    for (const error of [new Error(LEOS), new Error("peer disconnected")]) {
      await act(async () => root!.render(<PaneHostLine error={error} failingForMs={failingForMs} />));
      expect(container.textContent).toBe("");
      expect(container.querySelector('[role="alert"]')).toBeNull();
      expect(container.querySelector("button")).toBeNull();
    }
  }
});

test("a machine gone for minutes is one plain line with Retry, and acpmux's words only behind Details", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<PaneHostLine error={new Error(LEOS)} failingForMs={5 * 60_000} />);
  });
  const line = container.querySelector(".acpmux-host-line-message")!;
  expect(line.textContent).toBe("Can't reach <host>.");
  expect(buttons(container)).toEqual(["Retry", "Details"]);
  expect(container.textContent).not.toContain("peer_unreachable");
  expect(container.textContent).not.toContain("acpmux host ls");
  expect(container.querySelector(".acpmux-host-line-detail")).toBeNull();
  const details = [...container.querySelectorAll("button")].find((b) => b.textContent === "Details")!;
  expect(details.getAttribute("aria-expanded")).toBe("false");
  await act(async () => details.click());
  expect(details.getAttribute("aria-expanded")).toBe("true");
  expect(container.querySelector(".acpmux-host-line-detail")!.textContent).toBe(LEOS);
});

// The app never restarts a slow acpmux on its own (#28083, rule R5): a pane that waits long shows
// how long, and the person's Restart agent service is the one action.
test("a long wait for acpmux says how long and offers Restart agent service", async () => {
  const container = installDom();
  const pressed: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(<HostWaitingLine since={0} now={95_000} onRestart={() => pressed.push("restart")} />);
  });
  expect(container.textContent).toContain("Waiting for the agent service (1:35)");
  expect(buttons(container)).toEqual(["Restart agent service"]);
  await act(async () => container.querySelector("button")!.click());
  expect(pressed).toEqual(["restart"]);
});

test("a short wait for acpmux shows nothing", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<HostWaitingLine since={0} now={3_000} onRestart={() => undefined} />);
  });
  expect(container.textContent).toBe("");
});

test("a Restart agent service in flight holds its button", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<HostWaitingLine since={0} now={40_000} restarting onRestart={() => undefined} />);
  });
  expect(buttons(container)).toEqual(["Restarting agent service…"]);
  expect([...container.querySelectorAll("button")].every((b) => b.disabled)).toBe(true);
});

test("the wait reads as minutes and seconds", () => {
  expect(waitedText(0)).toBe("0:00");
  expect(waitedText(25_400)).toBe("0:25");
  expect(waitedText(605_000)).toBe("10:05");
});

test("one host line at a time: a long wait replaces an earlier failure's line", async () => {
  const container = installDom();
  const earlier = <p data-earlier>acpmux did not answer in time.</p>;
  await act(async () => {
    root = createRoot(container);
    root.render(<HostWaitingLine since={0} now={3_000} onRestart={() => undefined} otherwise={earlier} />);
  });
  expect(container.querySelector("[data-earlier]")).not.toBeNull();
  await act(async () => {
    root!.render(<HostWaitingLine since={0} now={30_000} onRestart={() => undefined} otherwise={earlier} />);
  });
  expect(container.querySelector("[data-earlier]")).toBeNull();
  expect(buttons(container)).toEqual(["Restart agent service"]);
});

test("a wait the host cannot restart keeps its time and shows no button", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<HostWaitingLine since={0} now={40_000} />);
  });
  expect(container.textContent).toContain("Waiting for the agent service (0:40)");
  expect(buttons(container)).toEqual([]);
});
