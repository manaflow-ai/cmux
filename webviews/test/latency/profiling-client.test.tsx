import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { useLayoutEffect, useState } from "react";

test("component state updates count as commits without another root.render request", async () => {
  const dom = new JSDOM("<!doctype html><main id='root'></main>", { url: "http://localhost/" });
  const saved = {
    window: globalThis.window,
    document: globalThis.document,
    hadWindow: "window" in globalThis,
    hadDocument: "document" in globalThis,
  };
  Object.assign(globalThis, { window: dom.window, document: dom.window.document });
  const { createRoot } = await import("./profiling-client");
  const scope = dom.window as unknown as {
    __latencyReactCommits: number;
    __latencyReactRootRenders: number;
    __latencyReactProfile: { source: string; phase: string; actualDuration: number };
  };
  let update: () => void = () => {};
  let painted: () => void = () => {};
  function Counter() {
    const [value, setValue] = useState(0);
    update = () => setValue((current) => current + 1);
    useLayoutEffect(() => painted(), [value]);
    return <p>{value}</p>;
  }
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    let commit = new Promise<void>((resolve) => (painted = resolve));
    root.render(<Counter />);
    await commit;
    expect(scope.__latencyReactCommits).toBe(1);
    expect(scope.__latencyReactRootRenders).toBe(1);
    commit = new Promise<void>((resolve) => (painted = resolve));
    update();
    update();
    await commit;
    expect(dom.window.document.querySelector("p")?.textContent).toBe("2");
    expect(scope.__latencyReactCommits).toBe(2);
    expect(scope.__latencyReactRootRenders).toBe(1);
    expect(scope.__latencyReactProfile.source).toBe("React.Profiler.onRender");
    expect(scope.__latencyReactProfile.phase).toBe("update");
    expect(scope.__latencyReactProfile.actualDuration).toBeGreaterThanOrEqual(0);
  } finally {
    root.unmount();
    // React's queued passive-effect callback still reads its document after unmount.
    await new Promise<void>((resolve) => setImmediate(resolve));
    for (const [key, existed] of [
      ["window", saved.hadWindow],
      ["document", saved.hadDocument],
    ] as const) {
      if (existed) Object.assign(globalThis, { [key]: saved[key] });
      else delete (globalThis as Record<string, unknown>)[key];
    }
    dom.window.close();
  }
});
