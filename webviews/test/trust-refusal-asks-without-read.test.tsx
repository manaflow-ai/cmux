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
function Chat(props: {
  trust: TrustSource;
  sessionId?: string;
  blockSend?: boolean;
  cwd?: string;
  authority?: () => unknown;
  visit?: () => unknown;
  /// Runs after React commits this render and before its effects: the client moving on meanwhile.
  onCommit?: () => void;
}) {
  latest = useFolderTrustAsk(
    props.trust,
    {
      sessionId: props.sessionId,
      cwd: props.cwd ?? peerFolder,
      prompts: 0,
      ...(props.authority ? { authority: props.authority } : {}),
      ...(props.visit ? { visit: props.visit } : {}),
    },
    true,
    false,
    props.blockSend,
  );
  const { onCommit } = props;
  React.useLayoutEffect(() => onCommit?.());
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

for (const path of ["failed row", "composer"] as const) {
  test(`Trust keeps the ${path} retry and its attachments until the pending folder choice completes`, async () => {
    const { source } = slowPeer();
    const sessionId = `pending-folder-${path}`;
    const staged = { text: "Use the attached plan", attachments: [{ id: "plan", data: "original bytes" }] };
    const deliveries: (typeof staged)[] = [];
    let takes = 0;
    const render = (blockSend: boolean) =>
      act(async () => root.render(<Chat key={sessionId} trust={source} sessionId={sessionId} blockSend={blockSend} />));
    await render(true);
    await act(async () => {
      latest!.refused({ reason: "trust.pending", cwd: peerFolder }, () => {
        takes++;
        deliveries.push(staged);
      });
    });
    await act(async () => latest!.trust());
    expect(deliveries).toEqual([]);
    expect(takes).toBe(0);
    // Confirmation stays blocked until the host accepts the folder; unrelated renders do not consume it.
    await render(true);
    expect(deliveries).toEqual([]);
    await render(false);
    expect(deliveries).toEqual([staged]);
    expect(deliveries[0]!.attachments).toBe(staged.attachments);
    expect(takes).toBe(1);
    await render(false);
    expect(takes).toBe(1);
  });
}

test("a pending folder choice begun while Trust saves still holds its retry", async () => {
  const { source } = slowPeer();
  let saved!: () => void;
  source.set = (cwd, level) => new Promise((resolve) => (saved = () => resolve({ cwd, level })));
  const render = (blockSend: boolean) =>
    act(async () => root.render(<Chat key="save-race" trust={source} sessionId="save-race" blockSend={blockSend} />));
  await render(false);
  let resent = 0;
  await act(async () => latest!.refused({ reason: "trust.pending", cwd: peerFolder }, () => resent++));
  await act(async () => latest!.trust());
  await render(true);
  await act(async () => saved());
  expect(resent).toBe(0);
  await render(false);
  expect(resent).toBe(1);
});

test("cancelling a pending folder choice keeps its trusted prompt unsent", async () => {
  const { source } = slowPeer();
  const render = (blockSend: boolean) =>
    act(async () =>
      root.render(<Chat key="cancel-folder" trust={source} sessionId="cancel-folder" blockSend={blockSend} />),
    );
  await render(true);
  const staged = { text: "Keep this draft", attachments: ["plan"] };
  let sent: typeof staged | undefined;
  await act(async () => latest!.refused({ reason: "trust.pending", cwd: peerFolder }, () => (sent = staged)));
  await act(async () => latest!.trust());
  act(() => latest!.cancelResend());
  await render(false);
  expect(sent).toBeUndefined();
  expect(staged).toEqual({ text: "Keep this draft", attachments: ["plan"] });
});

for (const change of ["chat", "folder"] as const) {
  test(`a trusted retry held by a folder choice never crosses a ${change} change`, async () => {
    const { source } = slowPeer();
    const render = (blockSend: boolean, changed = false) =>
      act(async () =>
        root.render(
          <Chat
            key={`switch-${change}`}
            trust={source}
            sessionId={changed && change === "chat" ? "other" : "original"}
            cwd={changed && change === "folder" ? "/other-folder" : peerFolder}
            blockSend={blockSend}
          />,
        ),
      );
    await render(true);
    let resent = 0;
    await act(async () => latest!.refused({ reason: "trust.pending", cwd: peerFolder }, () => resent++));
    await act(async () => latest!.trust());
    await render(false, true);
    expect(resent).toBe(0);
    await render(false);
    expect(resent).toBe(0);
  });
}

// Astra review of #25287 (P2): the folder choice can release a held retry while the client has
// already selected another chat (or connection) and React still shows the old one. The render's
// own checks pass then; the release must recheck the live visit and authority before replaying.
for (const moved of ["visit", "authority"] as const) {
  test(`a released trust retry is not sent once the live ${moved} has moved to another chat`, async () => {
    const { source } = slowPeer();
    let liveVisit = "original";
    let liveAuthority = "connection-1";
    const visit = () => liveVisit;
    const authority = () => liveAuthority;
    const moveOn = () => {
      if (moved === "visit") liveVisit = "other";
      else liveAuthority = "connection-2";
    };
    const render = (blockSend: boolean, onCommit?: () => void) =>
      act(async () =>
        root.render(
          <Chat
            key={`live-${moved}`}
            trust={source}
            sessionId="original"
            visit={visit}
            authority={authority}
            blockSend={blockSend}
            onCommit={onCommit}
          />,
        ),
      );
    await render(true);
    let resent = 0;
    await act(async () => latest!.refused({ reason: "trust.pending", cwd: peerFolder }, () => resent++));
    await act(async () => latest!.trust());
    expect(resent).toBe(0);
    // The folder choice completes in the same render the client moves to another chat.
    await render(false, moveOn);
    expect(resent).toBe(0);
  });
}

// Review at 72a044be (P2): fresh chats have no session id, so a retry held in one fresh chat must
// not be sent in the next fresh chat the pane shows once the folder choice lets go.
test("a fresh chat's held trust retry is not sent in another fresh chat", async () => {
  const { source } = slowPeer();
  let liveVisit = "fresh-a";
  const visit = () => liveVisit;
  const render = (blockSend: boolean) =>
    act(async () =>
      root.render(<Chat key="fresh-chats" trust={source} visit={visit} cwd={peerFolder} blockSend={blockSend} />),
    );
  await render(true);
  let resent = 0;
  await act(async () => latest!.refused({ reason: "trust.pending", cwd: peerFolder }, () => resent++));
  await act(async () => latest!.trust());
  expect(resent).toBe(0);
  liveVisit = "fresh-b";
  await render(false);
  expect(resent).toBe(0);
});

// Review at bee1fdb9 (P2): an established chat keeps its held retry across visits. Each selection
// moves the client's generation, so A → B → A is a new visit of the same chat.
test("an established chat's held trust retry survives leaving and coming back", async () => {
  const { source } = slowPeer();
  let generation = 1;
  const visit = () => JSON.stringify([generation, "chat-a"]);
  const render = (sessionId: string) =>
    act(async () => root.render(<Chat key="established-retry" trust={source} sessionId={sessionId} visit={visit} />));
  await render("chat-a");
  const sent: string[] = [];
  await act(async () => latest!.refused({ reason: "trust.pending", cwd: peerFolder }, () => sent.push("a")));
  generation += 1;
  await render("chat-b");
  generation += 1;
  await render("chat-a");
  await act(async () => latest!.trust());
  await render("chat-a");
  expect(sent).toEqual(["a"]);
});

// Review at 74163885 (P2): a refusal in fresh chat B must not overwrite fresh chat A's held retry;
// back in A, Trust still sends A's prompt.
test("each fresh chat keeps its own held trust retry", async () => {
  const { source } = slowPeer();
  let liveVisit = "fresh-a";
  const visit = () => liveVisit;
  const render = () =>
    act(async () => root.render(<Chat key="fresh-retries" trust={source} visit={visit} cwd={peerFolder} />));
  await render();
  const sent: string[] = [];
  await act(async () => latest!.refused({ reason: "trust.pending", cwd: peerFolder }, () => sent.push("a")));
  liveVisit = "fresh-b";
  await render();
  await act(async () => latest!.refused({ reason: "trust.pending", cwd: peerFolder }, () => sent.push("b")));
  liveVisit = "fresh-a";
  await render();
  await act(async () => latest!.trust());
  await render();
  expect(sent).toEqual(["a"]);
});

test("a throwing trust retry shows the failed trust question instead of escaping React", async () => {
  const { source } = slowPeer();
  await open(source, "throwing-retry");
  let attempts = 0;
  await act(async () => {
    latest!.refused({ reason: "trust.pending", cwd: peerFolder }, () => {
      attempts++;
      throw new Error("retry could not start");
    });
  });
  await act(async () => latest!.trust());
  expect(attempts).toBe(1);
  expect(latest!.ask).toMatchObject({ cwd: peerFolder, state: "failed" });
  expect(latest!.blocked?.reason).toBe("trust.answerFirst");
});
