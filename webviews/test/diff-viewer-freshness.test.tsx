// The diff viewer notices an agent's edit (cx-9ce.34, dogfood run hq #1893): it kept the old diff
// until the tab was reopened. It compares the host's fingerprint of its scope's diff with the one
// it loaded: coming back to the viewer after an edit refreshes it, unless a comment draft or the
// commit form would be lost, and then it says the files changed.
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
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  // The menu places itself with floating-ui, which reads the page's styles.
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act, useState } = await import("react");
const { createRoot } = await import("react-dom/client");
const { diffFingerprintReader, useDiffFreshness } = await import("../src/diff-viewer/freshness");

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

let onDisk = "a";
const calls: [string, unknown][] = [];
const page = {
  call: async (op: string, params: unknown) => {
    calls.push([op, params]);
    return { fingerprint: onDisk };
  },
  subscribe: async () => () => {},
};
const OPS = ["cmux.diff.git.fingerprint"];

function Viewer({
  read,
  canRefresh,
  refresh,
}: {
  read: () => Promise<string | undefined>;
  canRefresh: boolean;
  refresh: () => void;
}) {
  const [unavailable, setUnavailable] = useState<string>();
  const stale = useDiffFreshness(read, 0, () => canRefresh, refresh, setUnavailable);
  return (
    <>
      <output>{stale ? "stale" : "fresh"}</output>
      <aside>{unavailable}</aside>
    </>
  );
}
const shown = () => dom.window.document.querySelector("output")?.textContent;
const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

test("a repository's diffs are fingerprinted, Branch included (the chat's ± opens it; cx-4ukqc)", async () => {
  expect(diffFingerprintReader(page as never, OPS, { kind: "patch", path: "/tmp/x.patch" })).toBeUndefined();
  await diffFingerprintReader(page as never, OPS, { kind: "branch", repoRoot: "/r", baseRef: "main" })!();
  expect(calls.at(-1)).toEqual(["cmux.diff.git.fingerprint", { scope: "branch" }]);
  expect(diffFingerprintReader(page as never, [], { kind: "unstaged", repoRoot: "/r" })).toBeUndefined();
  await diffFingerprintReader(page as never, OPS, { kind: "branch", repoRoot: "/r", baseRef: "HEAD" })!();
  expect(calls.at(-1)).toEqual(["cmux.diff.git.fingerprint", { scope: "uncommitted" }]);
});

test("coming back after an edit refreshes the viewer", async () => {
  onDisk = "a";
  let refreshed = 0;
  const read = diffFingerprintReader(page as never, OPS, { kind: "unstaged", repoRoot: "/r" })!;
  await act(async () => root.render(<Viewer read={read} canRefresh refresh={() => (refreshed += 1)} />));
  await settle();
  dom.window.dispatchEvent(new dom.window.Event("focus"));
  await settle();
  expect(refreshed).toBe(0);

  onDisk = "b";
  dom.window.dispatchEvent(new dom.window.Event("focus"));
  await settle();
  expect(refreshed).toBe(1);
  expect(shown()).toBe("fresh");
});

test("with a draft or the commit form open it says the files changed instead", async () => {
  onDisk = "a";
  let refreshed = 0;
  const read = diffFingerprintReader(page as never, OPS, { kind: "staged", repoRoot: "/r" })!;
  await act(async () => root.render(<Viewer read={read} canRefresh={false} refresh={() => (refreshed += 1)} />));
  await settle();
  onDisk = "c";
  dom.window.dispatchEvent(new dom.window.Event("focus"));
  await settle();
  expect(refreshed).toBe(0);
  expect(shown()).toBe("stale");
});

test("an open Cloud diff reports disconnection and clears it after reconnect without losing its patch", async () => {
  let failure: Error | undefined;
  let refreshed = 0;
  const reason = "Build VM is offline. Reconnect to see its diff.";
  const read = async () => {
    if (failure) throw failure;
    return "same-patch";
  };
  await act(async () =>
    root.render(<Viewer key="machine-disconnect" read={read} canRefresh={false} refresh={() => (refreshed += 1)} />),
  );
  await settle();
  expect(shown()).toBe("fresh");

  failure = Object.assign(new Error(reason), { code: "cmux.diff.machine_offline" });
  dom.window.dispatchEvent(new dom.window.Event("focus"));
  await settle();
  expect(host.querySelector("aside")?.textContent).toBe(reason);
  expect(shown()).toBe("fresh");
  expect(refreshed).toBe(0);

  failure = undefined;
  dom.window.dispatchEvent(new dom.window.Event("focus"));
  await settle();
  expect(host.querySelector("aside")?.textContent).toBe("");
  expect(shown()).toBe("fresh");
  expect(refreshed).toBe(0);
});

test("a replaced source ignores a late offline failure from the old machine", async () => {
  let refuse: ((error: Error) => void) | undefined;
  const oldRead = () =>
    new Promise<string>((_resolve, reject) => {
      refuse = reject;
    });
  const refresh = () => {};
  await act(async () => root.render(<Viewer key="machine-race" read={oldRead} canRefresh={false} refresh={refresh} />));
  expect(typeof refuse).toBe("function");
  const newRead = async () => "new-machine";
  await act(async () => root.render(<Viewer key="machine-race" read={newRead} canRefresh={false} refresh={refresh} />));
  await settle();
  refuse?.(Object.assign(new Error("Old VM is offline"), { code: "cmux.diff.machine_offline" }));
  await settle();
  expect(host.querySelector("aside")?.textContent).toBe("");
  expect(shown()).toBe("fresh");
});
