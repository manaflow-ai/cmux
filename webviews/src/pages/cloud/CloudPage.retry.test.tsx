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

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
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
const { createRoot } = await import("react-dom/client");
const strings = createStrings(table);
const settle = async () => {
  for (let i = 0; i < 12; i++) await Promise.resolve();
};

afterAll(() => {
  jest.useRealTimers();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
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

for (const [name, failure] of [
  ["upstream", { code: "cmux.cloud.upstream_error", message: "Cloud did not answer", retryable: true }],
  ["malformed", { code: "cmux.protocol.invalid_result", message: "Malformed auth reply", retryable: false }],
  ["terminal", { code: "cmux.cloud.auth_required", message: "Sign in to cmux Cloud", retryable: false }],
] as const) {
  test(`renders ${name} auth failure with its error and Retry, then recovers`, async () => {
    const provider = new RetryFailureProvider(failure);
    const { root, rootElement, store } = await renderFailure(provider);
    try {
      expect(store.getSnapshot()).toMatchObject({
        connection: "failed",
        loading: false,
        error: failure.message,
      });
      expect(rootElement.querySelector(".cloud-loading")).toBeNull();
      expect(rootElement.querySelector(".cloud-failed")?.textContent).toContain(failure.message);
      const retry = rootElement.querySelector<HTMLButtonElement>(".cloud-failed .cloud-retry-button");
      expect(retry).not.toBeNull();
      await act(async () => {
        retry!.click();
        await settle();
      });
      expect(store.getSnapshot()).toMatchObject({ connection: "connected", loading: false });
      expect(rootElement.querySelector(".cloud-failed")).toBeNull();
      expect(rootElement.querySelector(".cloud-loading")).toBeNull();
    } finally {
      await act(async () => root.unmount());
      rootElement.remove();
      jest.useRealTimers();
    }
  });
}

for (const code of [
  "cmux.protocol.closed",
  "cmux.protocol.transport",
  "cmux.protocol.timeout",
  "cmux.protocol.unavailable",
]) {
  test(`a real bridge ${code} recovers without showing the failed page or clicking Retry`, async () => {
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
