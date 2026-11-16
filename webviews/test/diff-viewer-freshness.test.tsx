// The diff viewer notices an agent's edit (cx-9ce.34, dogfood run hq #1893): it kept the old diff
// until the tab was reopened. It compares the host's fingerprint of its scope's diff with the one
// it loaded: coming back to the viewer after an edit refreshes it, unless a comment draft or the
// commit form would be lost, and then it says the files changed.
import { afterAll, expect, spyOn, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

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

afterAll(async () => {
  act(() => root.unmount());
  await teardownDom(saved, { window: dom.window, scope });
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
// The reason that the viewer shows when its machine does not answer; empty when it shows none.
const reason = () => dom.window.document.querySelector("aside")?.textContent;
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

test("a session host without the fingerprint read gets no timer: each return asks again and reloads the diff", async () => {
  await act(async () => root.render(null));
  const intervals = spyOn(globalThis, "setInterval");
  const cleared = spyOn(globalThis, "clearInterval");
  let asked = 0;
  let refreshed = 0;
  let canRefresh = true;
  const read = async (): Promise<string> => {
    asked += 1;
    throw Object.assign(new Error("native.unsupported"), { code: "native.unsupported" });
  };
  const render = () =>
    act(async () =>
      root.render(<Viewer key="older-host" read={read} canRefresh={canRefresh} refresh={() => (refreshed += 1)} />),
    );
  try {
    await render();
    await settle();
    // The load asked once; the answer reloads nothing and stops the one timer it started.
    expect(asked).toBe(1);
    expect(refreshed).toBe(0);
    expect(intervals).toHaveBeenCalledTimes(1);
    const timer = intervals.mock.results[0]?.value;
    expect(cleared.mock.calls.some(([id]) => id === timer)).toBe(true);
    // The answer is not a failure for the reader: no notice and no reason are shown.
    expect([shown(), reason()]).toEqual(["fresh", ""]);

    for (let returns = 1; returns <= 3; returns += 1) {
      dom.window.dispatchEvent(new dom.window.Event("focus"));
      await settle();
      expect(refreshed).toBe(returns);
    }
    dom.window.dispatchEvent(new dom.window.Event("blur"));
    dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
    await settle();
    expect(refreshed).toBe(4);
    // Four returns: each asked one time more (the host sends an older session host nothing), and
    // no timer was started.
    expect(asked).toBe(5);
    expect(intervals).toHaveBeenCalledTimes(1);
    expect([shown(), reason()]).toEqual(["fresh", ""]);

    // A comment draft or the commit form would be lost: the return reloads nothing.
    canRefresh = false;
    await render();
    dom.window.dispatchEvent(new dom.window.Event("focus"));
    await settle();
    expect(refreshed).toBe(4);
    expect(asked).toBe(6);
    expect(shown()).toBe("fresh");
  } finally {
    await act(async () => root.render(null));
    intervals.mockRestore();
    cleared.mockRestore();
  }
});

test("a session host that gets the fingerprint read is compared again from the next return", async () => {
  await act(async () => root.render(null));
  const intervals = spyOn(globalThis, "setInterval");
  let older = true;
  let digits = "a";
  let asked = 0;
  let refreshed = 0;
  const read = async (): Promise<string> => {
    asked += 1;
    if (older) throw Object.assign(new Error("native.unsupported"), { code: "native.unsupported" });
    return digits;
  };
  const comeBack = async () => {
    dom.window.dispatchEvent(new dom.window.Event("blur"));
    dom.window.dispatchEvent(new dom.window.Event("focus"));
    await settle();
  };
  try {
    await act(async () =>
      root.render(<Viewer key="replaced-host" read={read} canRefresh refresh={() => (refreshed += 1)} />),
    );
    await settle();
    expect([asked, refreshed]).toEqual([1, 0]);
    expect(intervals).toHaveBeenCalledTimes(1);

    // The session host was replaced by one with the read. The return asks, gets digits and loads the
    // diff one time (the shown diff has no digits of its own). The answer itself starts no timer.
    older = false;
    await comeBack();
    expect([asked, refreshed]).toEqual([2, 1]);
    expect(intervals).toHaveBeenCalledTimes(1);

    // From here the digits decide: a return with the same digits loads nothing. The timer starts
    // again when the page loses the focus and when it gets it.
    await comeBack();
    expect([asked, refreshed]).toEqual([3, 1]);
    expect(intervals).toHaveBeenCalledTimes(3);
    digits = "b";
    await comeBack();
    expect([asked, refreshed]).toEqual([4, 2]);
    expect(shown()).toBe("fresh");
  } finally {
    await act(async () => root.render(null));
    intervals.mockRestore();
  }
});

test("one return to a page of a session host without the fingerprint read loads the diff one time", async () => {
  await act(async () => root.render(null));
  // The window has the focus when it is asked: a return ends the time that the page was away.
  const focused = spyOn(dom.window.document, "hasFocus").mockReturnValue(true);
  let refreshed = 0;
  const read = async (): Promise<string> => {
    throw Object.assign(new Error("native.unsupported"), { code: "native.unsupported" });
  };
  try {
    await act(async () =>
      root.render(<Viewer key="one-return" read={read} canRefresh refresh={() => (refreshed += 1)} />),
    );
    await settle();
    expect(refreshed).toBe(0);

    // One return gives two events: the page is visible again, and the window has the focus.
    dom.window.dispatchEvent(new dom.window.Event("blur"));
    dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
    dom.window.dispatchEvent(new dom.window.Event("focus"));
    await settle();
    expect(refreshed).toBe(1);

    // A focus event with no time away before it is no return.
    dom.window.dispatchEvent(new dom.window.Event("focus"));
    await settle();
    expect(refreshed).toBe(1);

    dom.window.dispatchEvent(new dom.window.Event("blur"));
    dom.window.dispatchEvent(new dom.window.Event("focus"));
    await settle();
    expect(refreshed).toBe(2);
  } finally {
    await act(async () => root.render(null));
    focused.mockRestore();
  }
});

/// A viewer whose load is a new generation, as the diff page's is: the freshness check starts again
/// after each load.
function LoadingViewer({ read, loaded }: { read: () => Promise<string | undefined>; loaded: () => void }) {
  const [generation, setGeneration] = useState(0);
  const stale = useDiffFreshness(
    read,
    generation,
    () => true,
    () => {
      loaded();
      setGeneration((now) => now + 1);
    },
  );
  return <output>{stale ? "stale" : "fresh"}</output>;
}

test("five returns to a page of a session host without the fingerprint read are five loads of the diff", async () => {
  await act(async () => root.render(null));
  const focused = spyOn(dom.window.document, "hasFocus").mockReturnValue(true);
  let loads = 0;
  const read = async (): Promise<string> => {
    throw Object.assign(new Error("native.unsupported"), { code: "native.unsupported" });
  };
  try {
    await act(async () => root.render(<LoadingViewer key="count" read={read} loaded={() => (loads += 1)} />));
    await settle();
    expect(loads).toBe(0);
    for (let returns = 1; returns <= 5; returns += 1) {
      dom.window.dispatchEvent(new dom.window.Event("blur"));
      dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
      dom.window.dispatchEvent(new dom.window.Event("focus"));
      // The load is a new generation: its own first check and a later turn start no load.
      await settle();
      await settle();
      expect(loads).toBe(returns);
    }
    expect(shown()).toBe("fresh");
  } finally {
    await act(async () => root.render(null));
    focused.mockRestore();
  }
});

test("a machine without the fingerprint read that is connected again shows no offline reason", async () => {
  await act(async () => root.render(null));
  const offline = "Build VM is offline. Reconnect to see its diff.";
  let failure = Object.assign(new Error(offline), { code: "cmux.diff.machine_offline" });
  let refreshed = 0;
  const read = async (): Promise<string> => {
    throw failure;
  };
  try {
    await act(async () =>
      root.render(
        <Viewer key="older-machine-offline" read={read} canRefresh={false} refresh={() => (refreshed += 1)} />,
      ),
    );
    await settle();
    expect(reason()).toBe(offline);
    // The machine is connected again, and its session host is older than the read.
    failure = Object.assign(new Error("native.unsupported"), { code: "native.unsupported" });
    dom.window.dispatchEvent(new dom.window.Event("focus"));
    await settle();
    expect([shown(), reason()]).toEqual(["fresh", ""]);
    // A comment draft or the commit form is open here: nothing is loaded.
    expect(refreshed).toBe(0);
  } finally {
    await act(async () => root.render(null));
  }
});

test("a session host that gets the fingerprint read while a draft is open says that the files changed", async () => {
  await act(async () => root.render(null));
  let older = true;
  let refreshed = 0;
  const read = async (): Promise<string> => {
    if (older) throw Object.assign(new Error("native.unsupported"), { code: "native.unsupported" });
    return "a";
  };
  try {
    await act(async () =>
      root.render(<Viewer key="replaced-host-draft" read={read} canRefresh={false} refresh={() => (refreshed += 1)} />),
    );
    await settle();
    expect(shown()).toBe("fresh");
    // The session host was replaced by one with the read. The shown diff has no digits of its own,
    // and a comment draft or the commit form would be lost: nothing is loaded, and the page says so.
    older = false;
    dom.window.dispatchEvent(new dom.window.Event("focus"));
    await settle();
    expect([shown(), refreshed]).toEqual(["stale", 0]);
  } finally {
    await act(async () => root.render(null));
  }
});

test("after the draft is closed, the next return loads the diff of a session host that got the fingerprint read", async () => {
  await act(async () => root.render(null));
  let older = true;
  let refreshed = 0;
  const read = async (): Promise<string> => {
    if (older) throw Object.assign(new Error("native.unsupported"), { code: "native.unsupported" });
    return "a";
  };
  const render = (canRefresh: boolean) =>
    act(async () =>
      root.render(
        <Viewer
          key="replaced-host-draft-closed"
          read={read}
          canRefresh={canRefresh}
          refresh={() => (refreshed += 1)}
        />,
      ),
    );
  try {
    await render(false);
    await settle();
    older = false;
    dom.window.dispatchEvent(new dom.window.Event("focus"));
    await settle();
    expect([shown(), refreshed]).toEqual(["stale", 0]);
    // The draft is closed and no file changed after that answer: the shown diff is still the one
    // from before the session host was replaced, so the return loads it.
    await render(true);
    dom.window.dispatchEvent(new dom.window.Event("focus"));
    await settle();
    expect(refreshed).toBe(1);
  } finally {
    await act(async () => root.render(null));
  }
});

test("while the reader stays in the page, a machine without the fingerprint read that is connected again loses its offline reason", async () => {
  await act(async () => root.render(null));
  const offline = "Build VM is offline. Reconnect to see its diff.";
  const older = Object.assign(new Error("native.unsupported"), { code: "native.unsupported" });
  let failure = older;
  let refreshed = 0;
  const read = async (): Promise<string> => {
    throw failure;
  };
  let ids = 0;
  const timers = new Map<number, () => void>();
  const intervals = spyOn(globalThis, "setInterval").mockImplementation(((tick: () => void) => {
    timers.set(++ids, tick);
    return ids;
  }) as unknown as typeof setInterval);
  const cleared = spyOn(globalThis, "clearInterval").mockImplementation((id) => {
    timers.delete(id as unknown as number);
  });
  try {
    await act(async () =>
      root.render(<Viewer key="older-machine-away" read={read} canRefresh={false} refresh={() => (refreshed += 1)} />),
    );
    await settle();
    // The machine is not connected at a return: the page says so.
    failure = Object.assign(new Error(offline), { code: "cmux.diff.machine_offline" });
    dom.window.dispatchEvent(new dom.window.Event("focus"));
    await settle();
    expect(reason()).toBe(offline);
    // The machine is connected again. The reader did not leave the page: no return asks again.
    failure = older;
    for (const tick of Array.from(timers.values())) await act(async () => tick());
    await settle();
    // The reason is gone, and no timer stays for a session host without the read.
    expect([reason(), timers.size, refreshed]).toEqual(["", 0, 0]);
  } finally {
    await act(async () => root.render(null));
    intervals.mockRestore();
    cleared.mockRestore();
  }
});

test("a machine without the fingerprint read that does not answer is asked again each 4 s with the focus and each 30 s without it, and never from a hidden page", async () => {
  await act(async () => root.render(null));
  let focused = true;
  let visibility = "visible";
  const focus = spyOn(document, "hasFocus").mockImplementation(() => focused);
  const originalVisibility = Object.getOwnPropertyDescriptor(document, "visibilityState");
  Object.defineProperty(document, "visibilityState", { configurable: true, get: () => visibility });
  let clock = 0;
  let nextId = 0;
  let wakeups = 0;
  const timers = new Map<number, { callback: () => void; delay: number; due: number }>();
  const interval = spyOn(globalThis, "setInterval").mockImplementation(((callback: () => void, delay = 0) => {
    const id = ++nextId;
    timers.set(id, { callback, delay, due: clock + delay });
    return id;
  }) as unknown as typeof setInterval);
  const clear = spyOn(globalThis, "clearInterval").mockImplementation((id) => {
    timers.delete(id as unknown as number);
  });
  const advance = async (ms: number) => {
    const end = clock + ms;
    for (;;) {
      const next = Array.from(timers.values()).sort((a, b) => a.due - b.due)[0];
      if (!next || next.due > end) break;
      clock = next.due;
      next.due += next.delay;
      wakeups++;
      await act(async () => next.callback());
    }
    clock = end;
  };
  const delays = () => Array.from(timers.values(), (timer) => timer.delay);
  const offline = "Build VM is offline. Reconnect to see its diff.";
  const older = Object.assign(new Error("native.unsupported"), { code: "native.unsupported" });
  const away = Object.assign(new Error(offline), { code: "cmux.diff.machine_offline" });
  let failure = older;
  let reads = 0;
  let refreshed = 0;
  // A read that waits for the machine: the test ends it by hand.
  let late: ((error: Error) => void) | undefined;
  let waits = false;
  const read = (): Promise<string> => {
    reads++;
    if (!waits) return Promise.reject(failure);
    return new Promise<string>((_resolve, reject) => {
      late = reject;
    });
  };
  try {
    await act(async () =>
      root.render(<Viewer key="older-machine-intervals" read={read} canRefresh refresh={() => refreshed++} />),
    );
    await settle();
    // A session host without the read whose machine answers: no timer.
    expect([reads, delays()]).toEqual([1, []]);

    // The machine is not connected at a return: the page asks again each 4 s.
    failure = away;
    await act(async () => window.dispatchEvent(new dom.window.Event("focus")));
    await settle();
    expect([reason(), reads, delays()]).toEqual([offline, 2, [4000]]);
    await advance(8_000);
    expect(reads).toBe(4);

    // Without the focus: each 30 s.
    focused = false;
    await act(async () => window.dispatchEvent(new dom.window.Event("blur")));
    expect(delays()).toEqual([30_000]);
    await advance(60_000);
    expect(reads).toBe(6);

    // The reader comes back and hides the page before the machine's answer is there.
    focused = true;
    waits = true;
    await act(async () => window.dispatchEvent(new dom.window.Event("focus")));
    expect(reads).toBe(7);
    visibility = "hidden";
    await act(async () => document.dispatchEvent(new dom.window.Event("visibilitychange")));
    expect(delays()).toEqual([]);
    waits = false;
    await act(async () => late?.(away));
    await settle();
    // The late answer starts nothing in a hidden page.
    expect(delays()).toEqual([]);
    const beforeHidden = wakeups;
    await advance(60_000);
    expect([wakeups, reads]).toEqual([beforeHidden, 7]);

    // The page is shown again and the machine is still not connected: the page asks again.
    visibility = "visible";
    await act(async () => document.dispatchEvent(new dom.window.Event("visibilitychange")));
    await settle();
    expect([reason(), reads, delays()]).toEqual([offline, 8, [4000]]);

    // The machine answers: the reason and the timer end, and the diff of the return loads one time.
    failure = older;
    await advance(4_000);
    await settle();
    expect([reason(), reads, delays(), refreshed]).toEqual(["", 9, [], 1]);
    const afterAnswer = wakeups;
    await advance(60_000);
    expect([wakeups, reads, refreshed]).toEqual([afterAnswer, 9, 1]);
  } finally {
    await act(async () => root.render(null));
    interval.mockRestore();
    clear.mockRestore();
    focus.mockRestore();
    if (originalVisibility) Object.defineProperty(document, "visibilityState", originalVisibility);
    else Reflect.deleteProperty(document, "visibilityState");
  }
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

test("freshness backs off while unfocused, checks on return, and stops waking while hidden or unmounted", async () => {
  await act(async () => root.render(null));
  let focused = true;
  let visibility = "visible";
  const focus = spyOn(document, "hasFocus").mockImplementation(() => focused);
  const originalVisibility = Object.getOwnPropertyDescriptor(document, "visibilityState");
  Object.defineProperty(document, "visibilityState", { configurable: true, get: () => visibility });
  let clock = 0;
  let nextId = 0;
  let wakeups = 0;
  const timers = new Map<number, { callback: () => void; delay: number; due: number }>();
  const interval = spyOn(globalThis, "setInterval").mockImplementation(((callback: () => void, delay = 0) => {
    const id = ++nextId;
    timers.set(id, { callback, delay, due: clock + delay });
    return id;
  }) as unknown as typeof setInterval);
  const clear = spyOn(globalThis, "clearInterval").mockImplementation((id) => {
    timers.delete(id as unknown as number);
  });
  const advance = async (ms: number) => {
    const end = clock + ms;
    for (;;) {
      const next = [...timers.values()].sort((a, b) => a.due - b.due)[0];
      if (!next || next.due > end) break;
      clock = next.due;
      next.due += next.delay;
      wakeups++;
      await act(async () => next.callback());
    }
    clock = end;
  };
  let reads = 0;
  let refreshed = 0;
  let fingerprint = "a";
  const read = async () => {
    reads++;
    return fingerprint;
  };
  try {
    await act(async () => root.render(<Viewer read={read} canRefresh refresh={() => refreshed++} />));
    expect(reads).toBe(1);
    await advance(12_000);
    expect(reads).toBe(4);

    focused = false;
    window.dispatchEvent(new dom.window.Event("blur"));
    await advance(60_000);
    expect(reads).toBe(6);
    expect(timers.size).toBe(1);
    fingerprint = "b";
    focused = true;
    await act(async () => window.dispatchEvent(new dom.window.Event("focus")));
    expect(refreshed).toBe(1);
    expect(reads).toBe(7);
    await advance(4_000);
    expect(reads).toBe(8);

    visibility = "hidden";
    document.dispatchEvent(new dom.window.Event("visibilitychange"));
    const beforeHidden = wakeups;
    await advance(60_000);
    expect(wakeups).toBe(beforeHidden);
    expect(timers.size).toBe(0);
    focused = false;
    visibility = "visible";
    await act(async () => document.dispatchEvent(new dom.window.Event("visibilitychange")));
    expect(reads).toBe(9);
    await advance(60_000);
    expect(reads).toBe(11);
    await act(async () => root.render(null));
    expect(timers.size).toBe(0);
    const beforeUnmount = wakeups;
    await advance(60_000);
    expect(wakeups).toBe(beforeUnmount);
  } finally {
    await act(async () => root.render(null));
    interval.mockRestore();
    clear.mockRestore();
    focus.mockRestore();
    if (originalVisibility) Object.defineProperty(document, "visibilityState", originalVisibility);
    else Reflect.deleteProperty(document, "visibilityState");
  }
});
