import { expect, test } from "bun:test";
import {
  createInspectorOrderStore,
  DEFAULT_INSPECTOR_ORDER,
  INSPECTOR_ORDER_KEY,
  moveSection,
} from "../src/agent-session/acpmux/inspector/sectionOrder";

function memory(raw: string | null = null) {
  const entries = new Map<string, string>(raw === null ? [] : [[INSPECTOR_ORDER_KEY, raw]]);
  return {
    getItem: (key: string) => entries.get(key) ?? null,
    setItem: (key: string, value: string) => {
      entries.set(key, value);
    },
    removeItem: (key: string) => {
      entries.delete(key);
    },
  };
}
const aOrder = moveSection(DEFAULT_INSPECTOR_ORDER, "changes", "context");
const bOrder = moveSection(DEFAULT_INSPECTOR_ORDER, "outputs", "environment");
const storageEvent = () => globalThis.dispatchEvent(Object.assign(new Event("storage"), { key: INSPECTOR_ORDER_KEY }));

test("native success clears only its stamped fallback and survives a relaunch", async () => {
  const storage = memory();
  const pane = createInspectorOrderStore(() => storage);
  let native: readonly string[] | undefined;
  let confirm!: () => void;
  pane.registerHost((value) => {
    native = value;
    return new Promise<void>((resolve) => {
      confirm = resolve;
    });
  });
  const writing = pane.set(aOrder);
  expect(pane.current()).toEqual(aOrder);
  expect(JSON.parse(storage.getItem(INSPECTOR_ORDER_KEY)!)).toEqual(native);
  confirm();
  await writing;
  expect(storage.getItem(INSPECTOR_ORDER_KEY)).toBeNull();
  const relaunched = createInspectorOrderStore(() => storage);
  relaunched.applyNative(native);
  expect(relaunched.current()).toEqual(aOrder);
});

test.each([false, true])("rejected native writes survive reload (advertised=%s)", async (advertised) => {
  const storage = memory();
  const pane = createInspectorOrderStore(() => storage);
  pane.applyNative(advertised ? DEFAULT_INSPECTOR_ORDER : undefined);
  pane.registerHost(async () => {
    throw new Error("unsupported or managed setting");
  });
  await pane.set(bOrder);
  const relaunched = createInspectorOrderStore(() => storage);
  relaunched.applyNative(advertised ? DEFAULT_INSPECTOR_ORDER : undefined);
  expect(relaunched.current()).toEqual(bOrder);
  expect(storage.getItem(INSPECTOR_ORDER_KEY)).not.toBeNull();
});

const interleavings = [
  "A B b-push a-ack b-ack reload",
  "A B b-push b-ack a-ack reload",
  "A a-ack B b-push b-ack reload",
  "A B a-ack b-push b-ack reload",
  "A B b-push a-stale-push a-ack b-ack reload",
  "A a-push B b-reject events reload",
  "A a-push B b-reject a-ack events reload",
  "A a-push a-ack B b-reject events reload",
  "A B b-push Reset r-push a-ack b-ack r-ack reload",
  "A B b-push Reset r-push r-ack b-ack a-ack reload",
  "Reset r-push A B b-push r-ack a-ack b-ack reload",
  "A Reset r-push r-ack B b-push a-ack b-ack reload",
  "A B b-push b-ack reload Reset r-push a-ack r-ack reload",
  "A a-push B b-reject Reset r-push a-ack r-ack reload",
];
test.each(interleavings)("newest order wins across panes: %s", async (steps) => {
  // Isolated module instances represent separate webviews sharing only localStorage and host pushes.
  const modulePath = "../src/agent-session/acpmux/inspector/sectionOrder.ts";
  type PaneModule = typeof import("../src/agent-session/acpmux/inspector/sectionOrder");
  const paneA = (await import(`${modulePath}?a-${encodeURIComponent(steps)}`)) as PaneModule;
  const paneB = (await import(`${modulePath}?b-${encodeURIComponent(steps)}`)) as PaneModule;
  const storage = memory();
  let a = paneA.createInspectorOrderStore(() => storage);
  let b = paneB.createInspectorOrderStore(() => storage);
  let cleanups = [a.subscribe(() => {}), b.subscribe(() => {})];
  type Request = { wire: readonly string[]; resolve: () => void; reject: () => void; done?: Promise<void> };
  const requests = new Map<string, Request>();
  let native: readonly string[] = DEFAULT_INSPECTOR_ORDER;
  let expected = DEFAULT_INSPECTOR_ORDER as readonly (typeof DEFAULT_INSPECTOR_ORDER)[number][];
  a.applyNative(native);
  b.applyNative(native);
  const capture = (pane: typeof a, id: string) => {
    pane.registerHost(
      (wire) =>
        new Promise<void>((resolve, reject) => {
          requests.set(id, { wire, resolve, reject: () => reject(new Error("managed setting")) });
        }),
    );
  };
  try {
    for (const step of steps.split(" ")) {
      if (step === "A" || step === "B") {
        const pane = step === "A" ? a : b;
        const id = step.toLowerCase();
        expected = step === "A" ? aOrder : bOrder;
        capture(pane, id);
        const done = pane.set(expected);
        requests.get(id)!.done = done;
      } else if (step === "Reset") {
        expected = DEFAULT_INSPECTOR_ORDER;
        capture(b, "r");
        const done = b.reset(); // Same versioned default payload that the native Reset writer broadcasts.
        requests.get("r")!.done = done;
      } else if (step.endsWith("push")) {
        const wire = requests.get(step[0]!)!.wire;
        if (!step.includes("stale")) native = wire;
        a.applyNative(wire);
        b.applyNative(wire);
      } else if (step.endsWith("ack") || step.endsWith("reject")) {
        const request = requests.get(step[0]!)!;
        if (step.endsWith("reject")) request.reject();
        else request.resolve();
        await request.done;
        // Reset uses the same async write path, without returning the promise to the display callback.
        await Promise.resolve();
      } else if (step === "reload") {
        cleanups.forEach((unsubscribe) => unsubscribe());
        a = paneA.createInspectorOrderStore(() => storage);
        b = paneB.createInspectorOrderStore(() => storage);
        a.applyNative(native);
        b.applyNative(native);
        cleanups = [a.subscribe(() => {}), b.subscribe(() => {})];
      }
      storageEvent();
      expect(a.current()).toEqual(expected);
      expect(b.current()).toEqual(expected);
    }
  } finally {
    cleanups.forEach((unsubscribe) => unsubscribe());
  }
});

test("equal timestamps converge by writer identity regardless of delivery order", () => {
  const low = ["@cmux-order/v1/123/a", ...aOrder];
  const high = ["@cmux-order/v1/123/b", ...bOrder];
  for (const delivery of [
    [low, high],
    [high, low],
  ]) {
    const pane = createInspectorOrderStore(() => memory());
    delivery.forEach(pane.applyNative);
    expect(pane.current()).toEqual(bOrder);
  }
});

test("legacy and malformed values normalize without exposing version metadata", () => {
  for (const raw of ["oops", "{}", "null"])
    expect(createInspectorOrderStore(() => memory(raw)).current()).toEqual(DEFAULT_INSPECTOR_ORDER);
  const storage = memory(JSON.stringify(["changes", "unknown", "changes", "context"]));
  expect(
    createInspectorOrderStore(() => storage)
      .current()
      .join(","),
  ).toBe("changes,context,environment,connectors,sources,outputs,subagents,tasks");
});

test("unavailable storage keeps memory, stable snapshots and unsubscribe", async () => {
  const unavailable = () => {
    throw new Error("storage unavailable");
  };
  const pane = createInspectorOrderStore(() => ({
    getItem: unavailable,
    setItem: unavailable,
    removeItem: unavailable,
  }));
  let notices = 0;
  const unsubscribe = pane.subscribe(() => notices++);
  await pane.set(aOrder);
  const snapshot = pane.current();
  await pane.set(aOrder);
  expect(pane.current()).toBe(snapshot);
  expect(notices).toBe(1);
  unsubscribe();
  await pane.reset();
  expect(pane.current()).toEqual(DEFAULT_INSPECTOR_ORDER);
  expect(notices).toBe(1);
});

test("moves before and after without mutating the input; dropping on itself is stable", () => {
  const original = Object.freeze([...DEFAULT_INSPECTOR_ORDER]);
  expect(moveSection(original, "context", "changes", true).slice(0, 4).join(",")).toBe(
    "environment,connectors,changes,context",
  );
  expect(original).toEqual(DEFAULT_INSPECTOR_ORDER);
  expect(moveSection(original, "changes", "changes")).toBe(original);
});
