import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { MemoryPersistence, checkpoint, list, target } from "./testFixture";
import { checkpointStrings as strings } from "./strings";
import type { CheckpointTarget } from "./protocol";
import type { CheckpointClientOptions, Request } from "./client";
const dom = new JSDOM("<!doctype html><div id=root></div>");
const values = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = new Map(Object.keys(values).map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
for (const [key, value] of Object.entries(values))
  Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });
afterAll(() => {
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else Reflect.deleteProperty(globalThis, key);
  }
  dom.window.close();
});
const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useCheckpoints } = await import("./controller");
function Pane({
  request,
  options,
  online = true,
  selected = target,
}: {
  request: Request;
  options: CheckpointClientOptions;
  online?: boolean;
  selected?: CheckpointTarget;
}) {
  const controller = useCheckpoints({ request, options, online, target: selected, strings });
  return (
    <>
      {controller.supported && (
        <button type="button" onClick={controller.show}>
          {strings.createCheckpoint}
        </button>
      )}
      {controller.review}
    </>
  );
}
function button(container: HTMLElement, label: string) {
  return [...container.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === label)!;
}

test("opening the inline capture action only reads candidates; Create approves exact paths", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const options = { persistence: new MemoryPersistence(), capabilities: async () => ({ checkpoints: true }) };
  const request: Request = async (method, params) => {
    calls.push({ method, params });
    return method.endsWith(".list") ? list : { result: checkpoint, revision: "1", replayed: false };
  };
  try {
    await act(async () => root.render(createElement(Pane, { request, options })));
    await act(async () => button(container, strings.createCheckpoint).click());
    expect(calls.map((call) => call.method)).toEqual(["git.checkpoint.list"]);
    await act(async () => button(container, strings.create).click());
    expect(calls[1]?.params).toMatchObject({
      cwd: "/repo",
      include_untracked: ["draft.txt"],
      expected_repository_id: "repo-1",
      expected_worktree_id: "worktree-1",
    });
    expect(container.textContent).toContain(checkpoint.ref);
  } finally {
    await act(async () => root.unmount());
  }
});

test("capabilities are read once per mount and again at reconnect, without probing a catalog", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  let reads = 0;
  const options = {
    persistence: new MemoryPersistence(),
    capabilities: async () => {
      reads++;
      return { checkpoints: false };
    },
  };
  const request: Request = async () => {
    throw new Error("No operations permitted");
  };
  try {
    await act(async () => root.render(createElement(Pane, { request, options })));
    expect(container.textContent).not.toContain(strings.createCheckpoint);
    await act(async () => root.render(createElement(Pane, { request, options })));
    expect(reads).toBe(1);
    await act(async () => root.render(createElement(Pane, { request, options, online: false })));
    await act(async () => root.render(createElement(Pane, { request, options, online: true })));
    expect(reads).toBe(2);
  } finally {
    await act(async () => root.unmount());
  }
});

test("cloud sessions never expose the local capture action", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const options = { persistence: new MemoryPersistence(), capabilities: async () => ({ checkpoints: true }) };
  try {
    await act(async () =>
      root.render(
        createElement(Pane, { request: async () => list, options, selected: { ...target, hostKind: "cloud" } }),
      ),
    );
    expect(container.textContent).not.toContain(strings.createCheckpoint);
  } finally {
    await act(async () => root.unmount());
  }
});

test("reopening after a timeout recovers the accepted checkpoint before offering another capture", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const persistence = new MemoryPersistence();
  const calls: string[] = [];
  const options = { persistence, capabilities: async () => ({ checkpoints: true }), key: () => "stable-key" };
  const request: Request = async (method) => {
    calls.push(method);
    if (method.endsWith(".list")) return list;
    if (method.endsWith(".get")) return checkpoint;
    throw { code: "native.timed_out", origin: "native", userMessage: "Reply lost" };
  };
  try {
    await act(async () => root.render(createElement(Pane, { request, options })));
    await act(async () => button(container, strings.createCheckpoint).click());
    await act(async () => button(container, strings.create).click());
    expect(button(container, strings.create).disabled).toBe(true);
    await act(async () => button(container, strings.cancel).click());
    await act(async () => root.unmount());
    const reloaded = createRoot(container);
    try {
      await act(async () => reloaded.render(createElement(Pane, { request, options })));
      await act(async () => button(container, strings.createCheckpoint).click());
      expect(calls).toEqual(["git.checkpoint.list", "git.checkpoint.create", "git.checkpoint.get"]);
      expect(container.textContent).toContain(checkpoint.ref);
    } finally {
      await act(async () => reloaded.unmount());
    }
  } finally {
    await act(async () => root.unmount());
  }
});

test("operation.unsupported hides capture controls after a definite owner answer", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const options = { persistence: new MemoryPersistence(), capabilities: async () => ({ checkpoints: true }) };
  try {
    await act(async () =>
      root.render(
        createElement(Pane, {
          request: async () => {
            throw { code: "operation.unsupported", origin: "session_host" };
          },
          options,
        }),
      ),
    );
    await act(async () => button(container, strings.createCheckpoint).click());
    expect(container.textContent).not.toContain(strings.createCheckpoint);
    expect(container.querySelector("section")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a new explicit review after a successful capture reads fresh candidates", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  let reads = 0;
  const options = { persistence: new MemoryPersistence(), capabilities: async () => ({ checkpoints: true }) };
  const request: Request = async (method) => {
    if (method.endsWith(".list")) {
      reads++;
      return list;
    }
    return { result: checkpoint, revision: "1", replayed: false };
  };
  try {
    await act(async () => root.render(createElement(Pane, { request, options })));
    await act(async () => button(container, strings.createCheckpoint).click());
    await act(async () => button(container, strings.create).click());
    await act(async () => button(container, strings.cancel).click());
    await act(async () => button(container, strings.createCheckpoint).click());
    expect(reads).toBe(2);
    expect(button(container, strings.create).disabled).toBe(false);
  } finally {
    await act(async () => root.unmount());
  }
});
