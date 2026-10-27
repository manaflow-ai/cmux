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
  local = false,
  sessionId = "migrating-chat",
}: {
  source: { get(cwd: string): Promise<unknown>; set(cwd: string, level: string): Promise<unknown> };
  cwd: string;
  authority: string;
  local?: boolean;
  sessionId?: string;
}) {
  const chat = { sessionId, cwd, family: "claude", prompts: 1, authority };
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
