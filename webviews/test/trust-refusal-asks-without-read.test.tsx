// Leo, 2026-10-21: a chat on a peer showed no trust question when the folder's read crossed the
// peer link slower than the pane waits for it (TRUST_READ_TIMEOUT_MS), so Send was refused with
// nothing to answer. acpmux's refusal names the folder and why (`trust_gate.rs`): the question
// draws from it when the read still gets no answer, and Trust sends the held prompt. A read that
// fails gets the pane the same nothing as one that times out (`readFolderTrust`), without a wait.
import { afterAll, expect, test } from "bun:test";
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
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const React = await import("react");
const { act } = React;
const { createRoot } = await import("react-dom/client");
const { useFolderTrustAsk } = await import("../src/agent-session/acpmux/useFolderTrustAsk");
type TrustSource = import("../src/agent-session/acpmux/folderTrust").TrustSource;

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const peerFolder = "/home/you/src/atlas";

/// A peer whose folder reads get no answer; answers are recorded.
function slowPeer() {
  const sets: [string, string][] = [];
  const source: TrustSource = {
    get: () => Promise.reject(new Error("no answer from the peer in time")),
    set: (cwd, level) => {
      sets.push([cwd, level]);
      return Promise.resolve({ cwd, level });
    },
  };
  return { source, sets };
}

let latest: ReturnType<typeof useFolderTrustAsk> | undefined;
function Chat(props: { trust: TrustSource; sessionId: string }) {
  latest = useFolderTrustAsk(props.trust, { sessionId: props.sessionId, cwd: peerFolder, prompts: 0 }, true, false);
  return null;
}
const open = (trust: TrustSource, sessionId: string) =>
  act(async () => root.render(<Chat key={sessionId} trust={trust} sessionId={sessionId} />));
const readGivesUp = () => act(async () => {});

test("a trust.pending refusal asks the question when the folder's read does not answer", async () => {
  const { source, sets } = slowPeer();
  await open(source, "peer-chat");
  await readGivesUp();
  // The read gave up: nothing to ask from it.
  expect(latest!.ask).toBeUndefined();
  let resent = 0;
  await act(async () => {
    expect(latest!.refused({ reason: "trust.pending", cwd: peerFolder }, () => resent++)).toBe(true);
  });
  await readGivesUp();
  expect(latest!.ask).toMatchObject({ cwd: peerFolder, state: "ask" });
  expect(latest!.blocked?.reason).toBe("trust.answerFirst");
  await act(async () => latest!.trust());
  expect(sets).toEqual([[peerFolder, "trusted"]]);
  expect(resent).toBe(1);
  expect(latest!.ask).toMatchObject({ cwd: peerFolder, state: "decided", level: "trusted" });
});

test("a trust.untrusted refusal shows Don't trust when the folder's read does not answer", async () => {
  const { source } = slowPeer();
  await open(source, "peer-chat-untrusted");
  await act(async () => {
    expect(latest!.refused({ reason: "trust.untrusted", cwd: peerFolder })).toBe(true);
  });
  await readGivesUp();
  expect(latest!.ask).toMatchObject({ cwd: peerFolder, state: "decided", level: "untrusted" });
  expect(latest!.blocked?.reason).toBe("trust.notTrustedNoPrompts");
});
