import { afterEach, expect, test } from "bun:test";
import { followScrollEdges } from "./scrollEdges";

type ObserverRecord = { callback: (records: MutationRecord[]) => void; disconnected: boolean };

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let mutations: ObserverRecord[] = [];
let observed = 0;
let unobserved = 0;

class TestResizeObserver {
  constructor(_callback: () => void) {}
  observe() {
    observed += 1;
  }
  unobserve() {
    unobserved += 1;
  }
  disconnect() {}
}

class TestMutationObserver {
  private readonly record: ObserverRecord;
  constructor(callback: (records: MutationRecord[]) => void) {
    this.record = { callback, disconnected: false };
    mutations.push(this.record);
  }
  observe() {}
  disconnect() {
    this.record.disconnected = true;
  }
}

function installDom() {
  for (const key of ["ResizeObserver", "MutationObserver"]) saved.set(key, scope[key]);
  Object.assign(scope, {
    ResizeObserver: TestResizeObserver,
    MutationObserver: TestMutationObserver,
  });
  mutations = [];
  observed = 0;
  unobserved = 0;
}

afterEach(() => {
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("tracks only changed children when a large scroller mutates, then disconnects", () => {
  installDom();
  const makeChild = () => ({ nodeType: 1 }) as unknown as Element;
  const node = {
    children: Array.from({ length: 192_000 }, makeChild),
    scrollHeight: 0,
    clientHeight: 0,
    scrollTop: 0,
    toggleAttribute() {},
    addEventListener() {},
    removeEventListener() {},
  } as unknown as HTMLElement & { children: Element[] };
  const stop = followScrollEdges(node);
  expect(observed).toBe(192_001);

  const child = makeChild();
  node.children.push(child);
  mutations[0]!.callback([
    {
      type: "childList",
      target: node,
      addedNodes: [child],
      removedNodes: [],
      previousSibling: null,
      nextSibling: null,
    } as unknown as MutationRecord,
  ]);
  expect(observed).toBe(192_002);

  node.children.pop();
  mutations[0]!.callback([
    {
      type: "childList",
      target: node,
      addedNodes: [],
      removedNodes: [child],
      previousSibling: null,
      nextSibling: null,
    } as unknown as MutationRecord,
  ]);
  expect(unobserved).toBe(1);

  stop();
  expect(mutations[0]!.disconnected).toBe(true);
});
