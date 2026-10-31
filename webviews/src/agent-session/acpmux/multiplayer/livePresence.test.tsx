// A shared chat's presence redraws only the header faces and the typing line (LivePresence.tsx):
// a teammate opening the chat or typing never sends the pane a snapshot, which would rebuild the
// whole transcript. Leo 2026-10-26: "we can still do the regular chat multiplayer".
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);

beforeAll(() => {
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node,
    Element: dom.window.Element,
  });
});
afterAll(() => {
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
});

type Hooks = {
  answer: (method: string, params: Record<string, unknown>) => Promise<unknown>;
  deliver: (message: unknown) => void;
};

const owner = { id: "owner", name: "Leo", devices: 1, viewing: true, typing: false };
const ana = { id: "tailnet:ana@example.com", name: "Ana", devices: 1, viewing: true, typing: false };

test("a teammate's presence reaches the live faces without a pane snapshot", async () => {
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const { shownPresence } = await import("./LivePresence");
  let hooks: Hooks | undefined;
  class SharedHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      // An acpmux that serves presence answers it on attach.
      hooks.answer = async (method, params) => {
        const reply = await answer(method, params);
        return method === "_acpmux/attach"
          ? { ...(reply as object), presence: { sessionId: params.sessionId, participants: [owner] } }
          : reply;
      };
    }
  }
  let snapshots = 0;
  let summary: unknown;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      snapshots += 1;
      summary = (snapshot as { summary?: unknown }).summary;
    },
    undefined,
    () => new SharedHost() as unknown as WebSocket,
  );
  // Waits for a condition, yielding a macrotask at a time (the mock host answers on its own turns).
  const settle = async (check: () => boolean) => {
    for (let i = 0; i < 2_000 && !check(); i += 1) await new Promise((resolve) => setTimeout(resolve, 0));
    expect(check()).toBe(true);
  };
  try {
    await settle(() => summary !== undefined);
    // The open's own snapshots are done once 50 turns pass with none.
    let seen = -1;
    let quiet = 0;
    await settle(() => {
      quiet = seen === snapshots ? quiet + 1 : 0;
      seen = snapshots;
      return quiet >= 50;
    });
    const before = snapshots;
    const changes: unknown[] = [];
    const stop = shownPresence.subscribe(() => changes.push(shownPresence.get()));
    hooks!.deliver({
      jsonrpc: "2.0",
      method: "_acpmux/presence",
      params: { sessionId: mockHost.sessionId, participants: [owner, { ...ana, typing: true }] },
    });
    await settle(() => changes.length > 0);
    expect(shownPresence.get()?.presence?.viewing.map((p) => p.id)).toEqual([ana.id]);
    expect(shownPresence.get()?.presence?.typing.map((p) => p.id)).toEqual([ana.id]);
    // Ana stops typing: the faces change again, and still no snapshot.
    hooks!.deliver({
      jsonrpc: "2.0",
      method: "_acpmux/presence",
      params: { sessionId: mockHost.sessionId, participants: [owner, ana] },
    });
    await settle(() => changes.length > 1);
    expect(shownPresence.get()?.presence?.typing).toEqual([]);
    expect(snapshots).toBe(before);
    stop();
  } finally {
    client.close?.();
  }
  // Closed: nobody shows.
  expect(shownPresence.get()).toBeUndefined();
});

test("the faces and typing line draw only over the chat the presence is for", async () => {
  const { createRoot } = await import("react-dom/client");
  const { act } = await import("react");
  const { LivePresenceStack, LiveTypingLine, shownPresence } = await import("./LivePresence");
  const scopeAct = scope as { IS_REACT_ACT_ENVIRONMENT?: boolean };
  scopeAct.IS_REACT_ACT_ENVIRONMENT = true;
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const presence = { viewing: [ana], typing: [ana] };
  const draw = (sessionId: string) =>
    act(async () =>
      root.render(
        <>
          <LivePresenceStack sessionId={sessionId} />
          <LiveTypingLine sessionId={sessionId} />
        </>,
      ),
    );
  try {
    // The next chat attached while the pane still shows the one before: nothing of it draws there.
    await act(async () => shownPresence.set("s2", presence));
    await draw("s1");
    expect(host.querySelector(".cv-presence")).toBeNull();
    expect(host.textContent).toBe("");
    await draw("s2");
    expect(host.querySelector(".cv-presence")).not.toBeNull();
    expect(host.textContent).toContain("Ana");
  } finally {
    await act(async () => root.unmount());
    await act(async () => shownPresence.set(undefined, undefined));
    host.remove();
    delete scopeAct.IS_REACT_ACT_ENVIRONMENT;
  }
});

test("a chat that opens with nobody else draws no faces its snapshot kept from before", async () => {
  const { createRoot } = await import("react-dom/client");
  const { act } = await import("react");
  const { LivePresenceStack, LiveTypingLine, shownPresence } = await import("./LivePresence");
  const { PresenceClient } = await import("./presenceClient");
  const scopeAct = scope as { IS_REACT_ACT_ENVIRONMENT?: boolean };
  scopeAct.IS_REACT_ACT_ENVIRONMENT = true;
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  // Wired as the pane wires it (direct.ts): every change sets the live store for the shown chat.
  const client: InstanceType<typeof PresenceClient> = new PresenceClient(
    () => {},
    () => shownPresence.set(client.chat, client.presence),
    () => "owner",
  );
  const stale = { viewing: [ana], typing: [ana] };
  const draw = (sessionId: string) =>
    act(async () =>
      root.render(
        <>
          <LivePresenceStack sessionId={sessionId} fallback={stale} />
          <LiveTypingLine sessionId={sessionId} fallback={stale} />
        </>,
      ),
    );
  try {
    for (const [sessionId, reply] of [
      ["s1", { events: [] }],
      [
        "s2",
        {
          presence: {
            sessionId: "s2",
            participants: [{ id: "owner", name: "Leo", devices: 1, viewing: true, typing: false }],
          },
        },
      ],
    ] as const) {
      await act(async () => client.attached(sessionId, reply));
      await draw(sessionId);
      expect(host.querySelector(".cv-presence")).toBeNull();
      expect(host.textContent).toBe("");
      await act(async () => client.detached());
    }
  } finally {
    await act(async () => root.unmount());
    await act(async () => shownPresence.set(undefined, undefined));
    host.remove();
    delete scopeAct.IS_REACT_ACT_ENVIRONMENT;
  }
});
