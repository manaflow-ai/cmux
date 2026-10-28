import { expect, test } from "bun:test";
import {
  createInspectorOrderStore,
  DEFAULT_INSPECTOR_ORDER,
  INSPECTOR_ORDER_KEY,
  INSPECTOR_ORDER_SETTING_KEY,
  applyInspectorOrder,
  moveSection,
  registerInspectorOrderHost,
} from "../src/agent-session/acpmux/inspector/sectionOrder";
import { setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";

function memory(raw: string | null = null) {
  const entries = new Map<string, string>(raw === null ? [] : [[INSPECTOR_ORDER_KEY, raw]]);
  return {
    getItem: (key: string) => entries.get(key) ?? null,
    setItem: (key: string, value: string) => entries.set(key, value),
    removeItem: (key: string) => entries.delete(key),
  };
}

function useStorage(storage: ReturnType<typeof memory>) {
  const previous = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  Object.defineProperty(globalThis, "localStorage", { configurable: true, value: storage });
  return () => {
    if (previous) Object.defineProperty(globalThis, "localStorage", previous);
    else Reflect.deleteProperty(globalThis, "localStorage");
  };
}

test("Changes above Context writes through the native preference and survives a relaunch", async () => {
  const native: unknown[] = [];
  registerInspectorOrderHost(async (value) => {
    native.push(value);
  });
  const storage = memory();
  try {
    const first = createInspectorOrderStore(() => storage);
    await first.set(moveSection(first.current(), "changes", "context"));
    expect(first.current().slice(0, 3)).toEqual(["environment", "changes", "context"]);
    expect(native).toEqual([first.current()]);
    // A new page receives the persisted native value through its display event before mounting.
    applyInspectorOrder(native[0]);
    expect(createInspectorOrderStore(() => memory()).current()).toEqual(first.current());
    expect(storage.getItem(INSPECTOR_ORDER_KEY)).toBeNull();
  } finally {
    registerInspectorOrderHost(undefined);
  }
});

test("resetting native settings clears the fallback and restores the default after relaunch", () => {
  const storage = memory();
  const restoreStorage = useStorage(storage);
  const native = moveSection(DEFAULT_INSPECTOR_ORDER, "changes", "context");
  registerInspectorOrderHost(async () => undefined);
  try {
    setChatDisplay({ [INSPECTOR_ORDER_SETTING_KEY]: native });
    expect(createInspectorOrderStore(() => storage).current()).toEqual(native);
    storage.setItem(INSPECTOR_ORDER_KEY, JSON.stringify(native));
    setChatDisplay({});
    expect(createInspectorOrderStore(() => storage).current()).toEqual(DEFAULT_INSPECTOR_ORDER);
    expect(storage.getItem(INSPECTOR_ORDER_KEY)).toBeNull();
  } finally {
    registerInspectorOrderHost(undefined);
    restoreStorage();
  }
});

test.each([false, true])("rejected native writes survive reload (host advertises setting=%s)", async (advertises) => {
  const storage = memory();
  const host = async () => {
    throw new Error("unsupported or managed setting");
  };
  registerInspectorOrderHost(host);
  try {
    setChatDisplay(advertises ? { [INSPECTOR_ORDER_SETTING_KEY]: DEFAULT_INSPECTOR_ORDER } : {});
    const first = createInspectorOrderStore(() => storage);
    const next = moveSection(first.current(), "changes", "context");
    await first.set(next);
    expect(JSON.parse(storage.getItem(INSPECTOR_ORDER_KEY)!)).toEqual(next);
    registerInspectorOrderHost(host); // A new page registers the same native route.
    setChatDisplay(advertises ? { [INSPECTOR_ORDER_SETTING_KEY]: DEFAULT_INSPECTOR_ORDER } : {});
    expect(createInspectorOrderStore(() => storage).current()).toEqual(next);
  } finally {
    registerInspectorOrderHost(undefined);
  }
});

test("Reset removes a rejected fallback as well as the native setting", async () => {
  const storage = memory();
  const restoreStorage = useStorage(storage);
  registerInspectorOrderHost(async () => {
    throw new Error("write rejected");
  });
  try {
    setChatDisplay({ [INSPECTOR_ORDER_SETTING_KEY]: DEFAULT_INSPECTOR_ORDER });
    const store = createInspectorOrderStore(() => storage);
    await store.set(moveSection(DEFAULT_INSPECTOR_ORDER, "changes", "context"));
    expect(storage.getItem(INSPECTOR_ORDER_KEY)).not.toBeNull();
    setChatDisplay({}); // Reset All removes the native key, even when its value was the default.
    store.applyExternal();
    expect(storage.getItem(INSPECTOR_ORDER_KEY)).toBeNull();
    registerInspectorOrderHost(async () => undefined);
    setChatDisplay({});
    expect(createInspectorOrderStore(() => storage).current()).toEqual(DEFAULT_INSPECTOR_ORDER);
  } finally {
    registerInspectorOrderHost(undefined);
    restoreStorage();
  }
});

test("native acknowledgement clears the fallback only after resolution", async () => {
  const storage = memory();
  let confirm!: () => void;
  registerInspectorOrderHost(
    () =>
      new Promise<void>((resolve) => {
        confirm = resolve;
      }),
  );
  try {
    const store = createInspectorOrderStore(() => storage);
    const next = moveSection(DEFAULT_INSPECTOR_ORDER, "changes", "context");
    const writing = store.set(next);
    applyInspectorOrder(next); // Display can arrive before the RPC response.
    expect(createInspectorOrderStore(() => storage).current()).toEqual(next);
    expect(storage.getItem(INSPECTOR_ORDER_KEY)).not.toBeNull();
    confirm();
    await writing;
    expect(storage.getItem(INSPECTOR_ORDER_KEY)).toBeNull();
  } finally {
    registerInspectorOrderHost(undefined);
  }
});

test.each([false, true])(
  "another pane's rejected fallback survives an earlier confirmation (late=%s)",
  async (late) => {
    // Separate module instances model independent webviews; only their storage is shared.
    const modulePath = "../src/agent-session/acpmux/inspector/sectionOrder.ts";
    type Pane = typeof import("../src/agent-session/acpmux/inspector/sectionOrder");
    const paneA = (await import(`${modulePath}?pane-a-${late}`)) as Pane;
    const paneB = (await import(`${modulePath}?pane-b-${late}`)) as Pane;
    const storage = memory();
    const a = paneA.createInspectorOrderStore(() => storage);
    const b = paneB.createInspectorOrderStore(() => storage);
    let confirm!: () => void;
    paneA.registerInspectorOrderHost(
      () =>
        new Promise<void>((resolve) => {
          confirm = resolve;
        }),
    );
    paneB.registerInspectorOrderHost(async () => {
      throw new Error("managed setting");
    });
    const unsubscribeA = a.subscribe(() => {});
    const unsubscribeB = b.subscribe(() => {});
    try {
      const savedA = moveSection(DEFAULT_INSPECTOR_ORDER, "changes", "context");
      const savedB = moveSection(DEFAULT_INSPECTOR_ORDER, "outputs", "environment");
      const writing = a.set(savedA);
      if (!late) {
        confirm();
        await writing;
      }
      await b.set(savedB);
      if (late) {
        confirm();
        await writing;
      }
      globalThis.dispatchEvent(Object.assign(new Event("storage"), { key: INSPECTOR_ORDER_KEY }));
      expect(JSON.parse(storage.getItem(INSPECTOR_ORDER_KEY)!)).toEqual(savedB);
      expect(a.current()).toEqual(savedB);
      expect(b.current()).toEqual(savedB);
      paneB.registerInspectorOrderHost(async () => {
        throw new Error("managed setting");
      });
      paneB.applyInspectorOrder(savedA); // Reload receives the last accepted native value.
      expect(paneB.createInspectorOrderStore(() => storage).current()).toEqual(savedB);
    } finally {
      unsubscribeA();
      unsubscribeB();
      paneA.registerInspectorOrderHost(undefined);
      paneB.registerInspectorOrderHost(undefined);
    }
  },
);

test("old or malformed storage keeps known order and appends missing sections", () => {
  for (const raw of ["oops", "{}", "null"]) {
    expect(createInspectorOrderStore(() => memory(raw)).current()).toEqual(DEFAULT_INSPECTOR_ORDER);
  }
  const storage = memory(JSON.stringify(["changes", "unknown", "changes", "context"]));
  expect(
    createInspectorOrderStore(() => storage)
      .current()
      .join(","),
  ).toBe("changes,context,environment,connectors,sources,outputs,subagents,tasks");
});

test.each([false, true])(
  "storage failure (readable=%s) keeps memory, stable snapshots and unsubscribe",
  async (readable) => {
    const unavailable = () => {
      throw new Error("storage unavailable");
    };
    const store = createInspectorOrderStore(() => ({
      getItem: readable ? () => null : unavailable,
      setItem: unavailable,
    }));
    const original = store.current();
    let notices = 0;
    const unsubscribe = store.subscribe(() => notices++);
    await store.set(moveSection(original, "changes", "context"));
    const changed = store.current();
    expect(changed).toBe(store.current());
    expect(changed).not.toEqual(original);
    await store.set(changed);
    expect(notices).toBe(1);
    unsubscribe();
    const again = store.subscribe(() => {});
    expect(store.current()).toBe(changed);
    again();
    await store.set(original);
    expect(notices).toBe(1);
  },
);

test("moves before and after without mutating the input; dropping on itself is stable", () => {
  const original = Object.freeze([...DEFAULT_INSPECTOR_ORDER]);
  expect(moveSection(original, "context", "changes", true).slice(0, 4).join(",")).toBe(
    "environment,connectors,changes,context",
  );
  expect(original).toEqual(DEFAULT_INSPECTOR_ORDER);
  expect(moveSection(original, "changes", "changes")).toBe(original);
});
