// A remote chat with no folder asked "Trust session-<id>?", and Trust folder answered only
// "Couldn't save that. Try again." while the host had refused the save with its reason (the folder
// was outside the machine's roots). The card kept that reason to itself, so nobody could tell a
// flaky save from one that can never work (remote GUI proof, 2026-11-10). The failed card now says
// why the save failed, beside the question it keeps asking.
import { afterAll, expect, test } from "bun:test";
import { settleReact } from "./support/domTeardown";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  MouseEvent: dom.window.MouseEvent,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const React = await import("react");
const { act } = React;
const { createRoot } = await import("react-dom/client");
const { useFolderTrustAsk } = await import("../src/agent-session/acpmux/useFolderTrustAsk");
const { TrustAsk } = await import("../src/agent-session/acpmux/TrustAsk");
type TrustSource = import("../src/agent-session/acpmux/folderTrust").TrustSource;

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
afterAll(async () => {
  act(() => root.unmount());
  await settleReact();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const folder = "/tmp/acpmux-peer-scratch-501-01a1/session-01a1c74c14be71d3964c4924a96cd844";
const refusal = "cwd is outside the folders this machine serves (webRoots)";

/// A host that reads the folder as unanswered and refuses every save with `error`.
function refusingHost(error: unknown): TrustSource {
  return {
    get: (cwd) => Promise.resolve({ cwd, level: "unknown", decided: false }),
    set: () => Promise.reject(error),
  };
}

let latest: ReturnType<typeof useFolderTrustAsk> | undefined;
function Chat(props: { trust: TrustSource }) {
  latest = useFolderTrustAsk(props.trust, { sessionId: "chat-remote", cwd: folder, prompts: 0 }, true, false);
  return latest.ask ? (
    <TrustAsk
      ask={latest.ask}
      agent="The agent"
      onTrust={latest.trust}
      onDistrust={latest.distrust}
      onUndo={latest.undo}
    />
  ) : null;
}

test("a refused Trust says why it failed and keeps the question", async () => {
  await act(async () => root.render(<Chat trust={refusingHost(new Error(refusal))} />));
  expect(latest!.ask?.state).toBe("ask");
  await act(async () => latest!.trust());
  expect(latest!.ask).toMatchObject({ state: "failed", cwd: folder, reason: refusal });
  const card = host.querySelector(".acpmux-trust-ask")!;
  expect(card.textContent).toContain("Couldn't save that. Try again.");
  expect(host.querySelector(".acpmux-trust-ask [role=alert]")?.textContent).toBe(refusal);
  // Trust stays offered: a later save may work.
  const buttons = [...card.querySelectorAll("button")].map((button) => button.textContent);
  expect(buttons).toContain("Trust folder");
});

test("a save that failed with no message shows only the generic line", async () => {
  await act(async () => root.render(<Chat trust={refusingHost(undefined)} key="silent" />));
  await act(async () => latest!.trust());
  expect(latest!.ask?.state).toBe("failed");
  expect(latest!.ask && "reason" in latest!.ask ? latest!.ask.reason : undefined).toBeUndefined();
  expect(host.querySelector(".acpmux-trust-ask [role=alert]")).toBeNull();
});
