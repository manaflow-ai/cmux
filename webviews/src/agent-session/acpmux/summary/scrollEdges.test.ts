import { afterEach, expect, test } from "bun:test";
import { followScrollEdges } from "./scrollEdges";

type ObserverRecord = {
  callback: (records: MutationRecord[]) => void;
  disconnected: boolean;
  target?: Node;
  options?: MutationObserverInit;
};
type ResizeRecord = { callback: () => void; disconnected: boolean };

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let mutations: ObserverRecord[] = [];
let resizes: ResizeRecord[] = [];
let observed = 0;
let unobserved = 0;

class TestResizeObserver {
  private readonly record: ResizeRecord;
  constructor(callback: () => void) {
    this.record = { callback, disconnected: false };
    resizes.push(this.record);
  }
  observe() {
    observed += 1;
  }
  unobserve() {
    unobserved += 1;
  }
  disconnect() {
    this.record.disconnected = true;
  }
}

class TestMutationObserver {
  private readonly record: ObserverRecord;
  constructor(callback: (records: MutationRecord[]) => void) {
    this.record = { callback, disconnected: false };
    mutations.push(this.record);
  }
  observe(target: Node, options: MutationObserverInit) {
    this.record.target = target;
    this.record.options = options;
  }
  disconnect() {
    this.record.disconnected = true;
  }
}

function installDom() {
  for (const key of ["ResizeObserver", "MutationObserver", "getComputedStyle"]) saved.set(key, scope[key]);
  Object.assign(scope, {
    ResizeObserver: TestResizeObserver,
    MutationObserver: TestMutationObserver,
    getComputedStyle: () => ({ direction: "ltr" }),
  });
  mutations = [];
  resizes = [];
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

function scroller() {
  const attributes = new Set<string>();
  const listeners = new Map<string, () => void>();
  const node = {
    nodeType: 1,
    parentNode: null,
    children: [] as Element[],
    scrollHeight: 100,
    clientHeight: 100,
    scrollTop: 0,
    scrollWidth: 100,
    clientWidth: 100,
    scrollLeft: 0,
    toggleAttribute(name: string, enabled: boolean) {
      if (enabled) attributes.add(name);
      else attributes.delete(name);
    },
    addEventListener(type: string, listener: () => void) {
      listeners.set(type, listener);
    },
    removeEventListener(type: string, listener: () => void) {
      if (listeners.get(type) === listener) listeners.delete(type);
    },
  } as unknown as HTMLElement & { children: Element[] };
  return { node, attributes, listeners, scroll: () => listeners.get("scroll")?.() };
}

// Deliver only mutations the fake platform observer actually subscribed to, so nested-content
// tests fail if the real helper watches direct children alone.
function mutate(target: Node, addedNodes: Node[] = [], removedNodes: Node[] = [], type = "childList") {
  for (const observer of mutations) {
    if (observer.disconnected) continue;
    const options = observer.options;
    if (type === "childList" ? !options?.childList : !options?.characterData) continue;
    let current: Node | null = target;
    while (current && current !== observer.target && options?.subtree) current = current.parentNode;
    if (current !== observer.target) continue;
    observer.callback([{ type, target, addedNodes, removedNodes } as unknown as MutationRecord]);
  }
}

function element(parentNode: Node, display = "block") {
  return {
    nodeType: 1,
    parentNode,
    children: [] as Element[],
    ownerDocument: { defaultView: { getComputedStyle: () => ({ display }) } },
  } as unknown as Element & { children: Element[] };
}

for (const [axis, direction] of [
  ["y", "ltr"],
  ["x", "ltr"],
  ["x", "rtl"],
] as const) {
  test(`${axis}/${direction}: a rounding-sized overflow leaves a completely visible last row unfaded`, () => {
    installDom();
    scope.getComputedStyle = () => ({ direction });
    const { node, attributes, scroll } = scroller();
    Object.assign(node, { scrollHeight: 101, scrollWidth: 101 });
    const stop = followScrollEdges(node, axis);
    expect([...attributes]).toEqual([]);
    for (const offset of [0.5, 1]) {
      node.scrollTop = offset;
      node.scrollLeft = direction === "rtl" ? -offset : offset;
      scroll();
      expect([...attributes]).toEqual([]);
    }
    // The tolerance is bounded: an actual two-pixel cutoff still advertises more content.
    Object.assign(node, { scrollHeight: 102, scrollWidth: 102, scrollTop: 0, scrollLeft: 0 });
    scroll();
    expect([...attributes]).toEqual([
      axis === "y" ? "data-fade-bottom" : direction === "rtl" ? "data-fade-left" : "data-fade-right",
    ]);
    stop();
  });
}

test("real vertical overflow follows top, middle and bottom and clears after resizing to fit", () => {
  installDom();
  const { node, attributes, listeners, scroll } = scroller();
  Object.assign(node, { scrollHeight: 300 });
  const stop = followScrollEdges(node);
  expect([...attributes]).toEqual(["data-fade-bottom"]);
  node.scrollTop = 100;
  scroll();
  expect(attributes.has("data-fade-top")).toBe(true);
  expect(attributes.has("data-fade-bottom")).toBe(true);
  node.scrollTop = 199;
  scroll();
  expect([...attributes]).toEqual(["data-fade-top"]);
  node.scrollTop = 200;
  scroll();
  expect([...attributes]).toEqual(["data-fade-top"]);
  Object.assign(node, { clientHeight: 300 });
  resizes[0]!.callback();
  expect([...attributes]).toEqual([]);
  stop();
  expect(resizes[0]!.disconnected).toBe(true);
  expect(mutations[0]!.disconnected).toBe(true);
  expect(listeners.size).toBe(0);
});

for (const direction of ["ltr", "rtl"] as const) {
  test(`real ${direction} horizontal overflow follows both edges`, () => {
    installDom();
    scope.getComputedStyle = () => ({ direction });
    const { node, attributes, scroll } = scroller();
    Object.assign(node, { scrollWidth: 300 });
    const stop = followScrollEdges(node, "x");
    expect([...attributes]).toEqual([direction === "rtl" ? "data-fade-left" : "data-fade-right"]);
    node.scrollLeft = direction === "rtl" ? -100 : 100;
    scroll();
    expect(attributes.has("data-fade-left")).toBe(true);
    expect(attributes.has("data-fade-right")).toBe(true);
    node.scrollLeft = direction === "rtl" ? -200 : 200;
    scroll();
    expect([...attributes]).toEqual([direction === "rtl" ? "data-fade-right" : "data-fade-left"]);
    stop();
  });
}

test("nested rows update capped-wrapper overflow without observing every descendant", () => {
  installDom();
  const { node, attributes } = scroller();
  const wrapper = element(node);
  node.children.push(wrapper);
  const stop = followScrollEdges(node);
  expect([...attributes]).toEqual([]);
  expect(observed).toBe(2);
  const row = element(wrapper);
  wrapper.children.push(row);
  Object.assign(node, { scrollHeight: 180 });
  mutate(wrapper, [row]);
  expect([...attributes]).toEqual(["data-fade-bottom"]);
  expect(observed).toBe(2);
  wrapper.children.pop();
  Object.assign(node, { scrollHeight: 100 });
  mutate(wrapper, [], [row]);
  expect([...attributes]).toEqual([]);
  stop();
});

test("nested text changes refresh wrapped overflow without resizing its outer box", () => {
  installDom();
  const { node, attributes } = scroller();
  const wrapper = element(node);
  node.children.push(wrapper);
  const stop = followScrollEdges(node);
  Object.assign(node, { scrollHeight: 180 });
  mutate({ nodeType: 3, parentNode: wrapper } as unknown as Node, [], [], "characterData");
  expect([...attributes]).toEqual(["data-fade-bottom"]);
  stop();
});

test("new children of a boxless wrapper are watched and released with that wrapper", () => {
  installDom();
  const { node } = scroller();
  const wrapper = element(node, "contents");
  const first = element(wrapper);
  wrapper.children.push(first);
  node.children.push(wrapper);
  const stop = followScrollEdges(node);
  expect(observed).toBe(2);
  const added = element(wrapper);
  wrapper.children.push(added);
  mutate(wrapper, [added]);
  expect(observed).toBe(3);
  node.children.pop();
  mutate(node, [], [wrapper]);
  expect(unobserved).toBe(2);
  stop();
});
