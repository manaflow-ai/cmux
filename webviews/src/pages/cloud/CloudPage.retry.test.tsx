import { act } from "react";
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { createStrings } from "../shared/i18n";
import { BridgePageClient, pageError } from "../shared/pageClient";
import { CloudPage } from "./CloudPage";
import table from "./generated/strings.json";
import { MockCloudProvider } from "./mockProvider";
import { CloudOps } from "./ops";
import { CLOUD_RESTART_MIN_MS, CloudStore } from "./store";
import { L } from "./strings";
import { LASTING_MS } from "../../ui/lasting";
import { teardownDom } from "../../../test/support/domTeardown";

// pretendToBeVisual gives the window requestAnimationFrame, which the create sheet's dialog uses.
const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
});
const globals = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
const { createRoot } = await import("react-dom/client");
const strings = createStrings(table);
const settle = async () => {
  for (let i = 0; i < 12; i++) await Promise.resolve();
};

afterAll(async () => {
  jest.useRealTimers();
  await teardownDom(saved, { window: dom.window, scope: globals });
});

class RetryFailureProvider extends MockCloudProvider {
  authReads = 0;
  constructor(private readonly failure: { code: string; message: string; retryable: boolean }) {
    super();
  }

  override async call<R>(op: string, params: unknown): Promise<R> {
    if (op === CloudOps.authStatus) {
      this.authReads += 1;
      if (this.authReads === 1) throw pageError("cmux.protocol.transport", "daemon restarting", true);
      if (this.authReads === 2) throw pageError(this.failure.code, this.failure.message, this.failure.retryable);
    }
    return super.call<R>(op, params);
  }
}

async function renderFailure(provider: RetryFailureProvider) {
  jest.useFakeTimers();
  const store = new CloudStore(provider);
  const rootElement = document.createElement("div");
  document.body.append(rootElement);
  const root = createRoot(rootElement);
  await act(async () => root.render(<CloudPage store={store} strings={strings} />));
  await act(async () => {
    await settle();
    jest.advanceTimersByTime(CLOUD_RESTART_MIN_MS);
    await settle();
  });
  return { root, rootElement, store };
}

// Leo, 2026-11-22: "i dont know what kind of decision a "try again" would be other than "ok i guess ill
// click this."" An auth read the owner answered with an error is read again on its own, like a lost
// link: no failed card and no Retry button, and the page comes up once a read succeeds.
for (const [name, failure] of [
  // Final; a retryable one is read again quietly before it shows (CloudPage.blip.test.tsx).
  ["upstream", { code: "cmux.cloud.upstream_error", message: "Cloud did not answer", retryable: false }],
  ["malformed", { code: "cmux.protocol.invalid_result", message: "Malformed auth reply", retryable: false }],
  ["terminal", { code: "cmux.cloud.auth_required", message: "Sign in to cmux Cloud", retryable: false }],
] as const) {
  test(`a ${name} auth failure shows nothing, offers no Retry, and recovers on its own`, async () => {
    const provider = new RetryFailureProvider(failure);
    const { root, rootElement, store } = await renderFailure(provider);
    try {
      expect(store.getSnapshot()).toMatchObject({ connection: "failed", loading: false, recovering: true });
      expect(provider.authReads).toBe(2);
      expect(rootElement.querySelector(".cloud-loading")).toBeNull();
      expect(rootElement.querySelector(".cloud-still-trying")).toBeNull();
      expect(rootElement.querySelector("button")).toBeNull();
      expect(rootElement.textContent).not.toContain(strings.t(L.retry));
      // The second failure waits twice as long before the next read.
      await act(async () => {
        jest.advanceTimersByTime(CLOUD_RESTART_MIN_MS * 2);
        await settle();
      });
      expect(provider.authReads).toBe(3);
      expect(store.getSnapshot()).toMatchObject({ connection: "connected", loading: false });
      expect(store.getSnapshot().recovering).toBeUndefined();
      expect(store.getSnapshot().error).toBeUndefined();
      expect(rootElement.querySelector(".cloud-still-trying")).toBeNull();
      expect(rootElement.querySelector(".cloud-loading")).toBeNull();
    } finally {
      await act(async () => root.unmount());
      rootElement.remove();
      jest.useRealTimers();
    }
  });
}

test("an outage that lasts says so in one quiet line with no button, and keeps reading", async () => {
  class DownProvider extends MockCloudProvider {
    authReads = 0;
    override async call<R>(op: string, params: unknown): Promise<R> {
      if (op === CloudOps.authStatus) {
        this.authReads += 1;
        throw pageError("cmux.cloud.upstream_error", "Cloud did not answer", true);
      }
      return super.call<R>(op, params);
    }
  }
  jest.useFakeTimers();
  const provider = new DownProvider();
  const store = new CloudStore(provider);
  const rootElement = document.createElement("div");
  document.body.append(rootElement);
  const root = createRoot(rootElement);
  try {
    await act(async () => {
      root.render(<CloudPage store={store} strings={strings} />);
      await settle();
    });
    expect(rootElement.querySelector(".cloud-still-trying")).toBeNull();
    // Past the grace, in steps, so each re-read the timers arm on the way settles.
    for (let elapsed = 0; elapsed <= LASTING_MS; elapsed += 1_000) {
      await act(async () => {
        jest.advanceTimersByTime(1_000);
        await settle();
      });
    }
    const line = rootElement.querySelector(".cloud-still-trying");
    expect(line?.textContent).toBe(strings.t(L.stillTrying));
    expect(rootElement.querySelector("button")).toBeNull();
    expect(rootElement.querySelector(".cloud-failed")).toBeNull();
    // 1, 2, 4, 8 s and then every 10 s: the reads went on all along.
    expect(provider.authReads).toBeGreaterThanOrEqual(5);
  } finally {
    await act(async () => root.unmount());
    rootElement.remove();
    jest.useRealTimers();
  }
});

for (const code of [
  "cmux.protocol.closed",
  "cmux.protocol.transport",
  "cmux.protocol.timeout",
  "cmux.protocol.unavailable",
]) {
  test(`a real bridge ${code} recovers on its own without showing anything`, async () => {
    jest.useFakeTimers();
    let reads = 0;
    const client = new BridgePageClient(
      {
        async postMessage(body) {
          const { id, t } = body as { id: number; t: string };
          // Only auth reads count: the account stream's subscribe (a `sub`) gets no sub id and is dropped.
          if (t !== "call") return { t: "ok", id, value: {} };
          reads += 1;
          if (reads === 1) return { t: "err", id, code, message: "bridge unavailable" };
          return { t: "ok", id, value: { signedIn: false } };
        },
      },
      {},
    );
    const store = new CloudStore(client);
    const rootElement = document.createElement("div");
    document.body.append(rootElement);
    const root = createRoot(rootElement);
    try {
      await act(async () => {
        root.render(<CloudPage store={store} strings={strings} />);
        await settle();
      });
      expect(store.getSnapshot().connection).toBe("disconnected");
      expect(rootElement.querySelector(".cloud-failed")).toBeNull();
      expect(rootElement.querySelector(".cloud-loading")).toBeNull();
      await act(async () => {
        jest.advanceTimersByTime(CLOUD_RESTART_MIN_MS);
        await settle();
      });
      expect(reads).toBe(2);
      expect(store.getSnapshot()).toMatchObject({ connection: "connected", loading: false });
      expect(store.getSnapshot().error).toBeUndefined();
      expect(rootElement.querySelector(".cloud-failed")).toBeNull();
      expect(rootElement.querySelector(".cloud-loading")).toBeNull();
    } finally {
      await act(async () => root.unmount());
      rootElement.remove();
      jest.useRealTimers();
    }
  });
}

test("a failed snapshot list is read again on its own in the create sheet, with no Retry", async () => {
  jest.useFakeTimers();
  const provider = new MockCloudProvider();
  const store = new CloudStore(provider);
  const rootElement = document.createElement("div");
  document.body.append(rootElement);
  const root = createRoot(rootElement);
  const lists = () => provider.calls.filter((call) => call.op === CloudOps.snapshotList).length;
  try {
    await act(async () => {
      root.render(<CloudPage store={store} strings={strings} />);
      await settle();
    });
    provider.failNext = CloudOps.snapshotList;
    await act(async () => {
      store.openCreate();
      await settle();
    });
    expect(store.getSnapshot().create?.snapshotsFailed).toBe(true);
    expect(document.querySelector(".cloud-create-snapshots-failed")).toBeNull();
    expect(document.body.textContent).not.toContain(strings.t(L.retry));
    const before = lists();
    // The first ask comes within the jittered first second.
    await act(async () => {
      jest.advanceTimersByTime(1_000);
      await settle();
    });
    expect(lists()).toBe(before + 1);
    const draft = store.getSnapshot().create!;
    expect(draft.snapshotsFailed).toBeUndefined();
    expect(draft.snapshots?.length).toBe(provider.snapshots.length);
  } finally {
    await act(async () => root.unmount());
    rootElement.remove();
    jest.useRealTimers();
  }
});
