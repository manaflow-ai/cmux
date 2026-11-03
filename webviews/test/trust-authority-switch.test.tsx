import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useFolderTrustAsk } = await import("../src/agent-session/acpmux/useFolderTrustAsk");
type Hook = ReturnType<typeof useFolderTrustAsk>;
const host = dom.window.document.getElementById("root")!;
let root: ReturnType<typeof createRoot>;
let shown: Hook;
const pending = (cwd: string) => ({ reason: "trust.pending", cwd });
const deferred = <T,>() => {
  let resolve!: (value: T) => void;
  return { promise: new Promise<T>((done) => (resolve = done)), resolve: (value: T) => resolve(value) };
};
const trusted = (cwd: string) => ({ cwd, level: "trusted", decided: true });
const unknown = (cwd: string) => ({ cwd, level: "unknown" });

function Probe({
  source,
  cwd,
  authority,
  visit,
  local = false,
  sessionId = "migrating-chat",
}: {
  source: { get(cwd: string): Promise<unknown>; set(cwd: string, level: string): Promise<unknown> };
  cwd: string;
  authority: string | (() => string);
  visit?: () => number;
  local?: boolean;
  sessionId?: string;
}) {
  const chat = { sessionId, cwd, family: "claude", prompts: 1, authority, visit };
  shown = useFolderTrustAsk(source, chat, true, local);
  return null;
}

beforeEach(() => {
  root = createRoot(host);
});
afterEach(async () => act(() => root.unmount()));
afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
});

for (const fromLocal of [true, false]) {
  test(`${fromLocal ? "local" : "peer"} trust cannot follow an equal cwd to another peer`, async () => {
    const cwd = `/home/you/shared-${fromLocal}`;
    const readB = deferred<unknown>();
    let onB = false;
    let reads = 0;
    const source = {
      get: async () => {
        reads++;
        return onB ? readB.promise : trusted(cwd);
      },
      set: async () => undefined,
    };
    await act(async () => root.render(<Probe source={source} cwd={cwd} authority="A" local={fromLocal} />));
    expect(shown.trusted).toBe(true);
    onB = true;
    await act(async () => root.render(<Probe source={source} cwd={cwd} authority="B" />));
    expect(shown.trusted).toBe(false);
    expect(reads).toBe(2);
    await act(async () => readB.resolve(unknown(cwd)));
    expect(shown.ask).toMatchObject({ cwd, state: "ask" });
  });
}

test("a completed Trust save cannot grant or replay into a new authority with the same chat id and cwd", async () => {
  const cwd = "/home/you/migrated-save";
  const saveA = deferred<unknown>();
  const readB = deferred<unknown>();
  let onB = false;
  let resent = 0;
  const source = {
    get: async () => (onB ? readB.promise : trusted(cwd)),
    set: () => saveA.promise,
  };
  await act(async () => root.render(<Probe source={source} cwd={cwd} authority="A" />));
  await act(async () => shown.refused(pending(cwd), () => resent++));
  await act(async () => shown.trust());
  onB = true;
  await act(async () => root.render(<Probe source={source} cwd={cwd} authority="B" />));
  await act(async () => saveA.resolve(undefined));
  expect(resent).toBe(0);
  expect(shown.trusted).toBe(false);
  await act(async () => readB.resolve(unknown(cwd)));
  expect(shown.ask).toMatchObject({ cwd, state: "ask" });
});

test("a captured refusal cannot attach to another chat or a later visit to the same chat", async () => {
  const cwd = "/home/you/late-refusal";
  const source = { get: async () => trusted(cwd), set: async () => undefined };
  const show = (sessionId: string) =>
    act(async () => root.render(<Probe source={source} cwd={cwd} authority="A" sessionId={sessionId} />));
  await show("chat-a");
  const lateRefusal = shown.refused;
  await show("chat-b");
  await act(async () => expect(lateRefusal(pending(cwd))).toBe(false));
  expect(shown.ask).toBeUndefined();
  await show("chat-a");
  await act(async () => expect(lateRefusal(pending(cwd))).toBe(false));
  expect(shown.ask).toBeUndefined();
});

test("a route change fences a completed save before React renders the new authority", async () => {
  const cwd = "/home/you/pre-render-save";
  const saveA = deferred<unknown>();
  const route = { current: "A" };
  const authority = () => route.current;
  const source = { get: async () => trusted(cwd), set: () => saveA.promise };
  let resent = 0;
  await act(async () => root.render(<Probe source={source} cwd={cwd} authority={authority} />));
  await act(async () => shown.refused(pending(cwd), () => resent++));
  await act(async () => shown.trust());
  route.current = "B";
  await act(async () => saveA.resolve(undefined));
  expect(resent).toBe(0);
  expect(shown.trusted).toBe(false);
});

test("a local authority keeps trusted folders cached across A to B to A", async () => {
  const folderA = "/home/you/cache-a";
  const folderB = "/home/you/cache-b";
  let reads = 0;
  const rereadA = deferred<unknown>();
  const source = {
    get: async (cwd: string) => {
      reads++;
      if (cwd === folderA && reads === 3) return rereadA.promise;
      return trusted(cwd);
    },
    set: async () => undefined,
  };
  const show = (cwd: string) =>
    act(async () => {
      root.render(<Probe source={source} cwd={cwd} authority="A" local />);
      await Promise.resolve();
      await Promise.resolve();
    });
  await show(folderA);
  expect(shown.trusted).toBe(true);
  await show(folderB);
  expect(shown.trusted).toBe(true);
  await show(folderA);
  expect(shown.trusted).toBe(true);
  expect(shown.blocked).toBeUndefined();
  expect(reads).toBe(3);
  await act(async () => rereadA.resolve(trusted(folderA)));
});

test("a first-client trust refusal survives the generation bind before React renders", async () => {
  const cwd = "/home/you/new-session";
  let generation: number | undefined;
  const source = { get: async () => trusted(cwd), set: async () => undefined };
  await act(async () => root.render(<Probe source={source} cwd={cwd} authority="A" visit={() => generation!} />));
  const beforeClient = shown.refused;
  generation = 1;
  await act(async () => {
    expect(beforeClient(pending(cwd), () => undefined)).toBe(true);
    await Promise.resolve();
  });
  expect(shown.ask).toMatchObject({ cwd, state: "ask" });
});

test("an older same-authority save cannot erase a newer refusal for that chat", async () => {
  const cwd = "/home/you/newer-refusal";
  const save = deferred<unknown>();
  let visit = 1;
  const source = { get: async () => trusted(cwd), set: () => save.promise };
  const show = () =>
    act(async () => root.render(<Probe source={source} cwd={cwd} authority="A" visit={() => visit} />));
  await show();
  await act(async () => shown.refused(pending("/home/you/f1")));
  await act(async () => shown.trust());
  visit = 2;
  await show();
  visit = 1;
  await show();
  await act(async () => shown.refused(pending("/home/you/f2")));
  await act(async () => save.resolve(undefined));
  expect(shown.ask?.cwd).toBe("/home/you/f2");
});

test("a newer same-visit refusal keeps its folder and replay over an older save", async () => {
  const cwd = "/home/you/same-visit-refusal";
  const save = deferred<unknown>();
  let resentOld = 0;
  let resentNew = 0;
  const source = { get: async () => trusted(cwd), set: () => save.promise };
  await act(async () => root.render(<Probe source={source} cwd={cwd} authority="A" visit={() => 1} />));
  await act(async () => shown.refused(pending("/home/you/f1"), () => resentOld++));
  await act(async () => shown.trust());
  await act(async () => shown.refused(pending("/home/you/f2"), () => resentNew++));
  await act(async () => save.resolve(undefined));
  expect(shown.ask?.cwd).toBe("/home/you/f2");
  await act(async () => shown.trust());
  expect(resentOld).toBe(0);
  expect(resentNew).toBe(1);
});

test("a delayed prompt refusal is dropped after direct-client navigation", async () => {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  const entered = deferred<unknown>();
  const reply = deferred<unknown>();
  class RefusingHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as {
        answer(method: string, params: Record<string, unknown>): Promise<unknown>;
      };
      const answer = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method !== "session/prompt") return answer(method, params);
        entered.resolve(undefined);
        return reply.promise.then(() => {
          throw Object.assign(new Error("trust.pending"), {
            code: -32000,
            data: { reason: "trust.pending", cwd: "/home/you/original" },
          });
        });
      };
    }
  }
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new RefusingHost() as unknown as WebSocket,
  );
  try {
    let routed = 0;
    client.onTrustRefused = () => routed++;
    const sent = client.send("original prompt", [], undefined, () => undefined).catch(() => undefined);
    await entered.promise;
    await client.select("mock-sidebar-flicker");
    reply.resolve(undefined);
    await sent;
    expect(routed).toBe(0);
  } finally {
    client.close();
  }
});

test("a same-host selection change fences forced replay before React renders", async () => {
  const cwd = "/home/you/pre-render-visit";
  const save = deferred<unknown>();
  let selection = 1;
  const visit = () => selection;
  const source = { get: async () => trusted(cwd), set: () => save.promise };
  let resent = 0;
  await act(async () => root.render(<Probe source={source} cwd={cwd} authority="A" visit={visit} />));
  await act(async () => shown.refused(pending(cwd), () => resent++));
  const lateRefusal = shown.refused;
  await act(async () => shown.trust());
  selection++;
  expect(lateRefusal(pending(cwd))).toBe(false);
  await act(async () => save.resolve(undefined));
  expect(resent).toBe(0);
});

test("a canceled send cannot route its late refusal through a fresh handler", async () => {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  const entered = deferred<unknown>();
  const reply = deferred<unknown>();
  class RefusingHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as {
        answer(method: string, params: Record<string, unknown>): Promise<unknown>;
      };
      const answer = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method !== "session/prompt") return answer(method, params);
        entered.resolve(undefined);
        return reply.promise.then(() => {
          throw Object.assign(new Error("trust.pending"), {
            code: -32000,
            data: { reason: "trust.pending", cwd: "/home/you/original" },
          });
        });
      };
    }
  }
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new RefusingHost() as unknown as WebSocket,
  );
  try {
    let routed = 0;
    client.onTrustRefused = () => routed++;
    const sent = client.send("original prompt", [], undefined, () => undefined).catch(() => undefined);
    await entered.promise;
    client.cancelTrustRefusals();
    // React replaces its mutable handler after the folder dialog closes. A fresh handler
    // must not give the canceled request a new retry identity.
    client.onTrustRefused = () => routed++;

    reply.resolve(undefined);
    await sent;
    expect(routed).toBe(0);
  } finally {
    client.close();
  }
});
