import { afterEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  __resetCodeBridgeForTests,
  createDesktopBridge,
  ensureCodeMounted,
  installCodeBridge,
  installNativeFetch,
  installNativeWebSocket,
  markNativeCodeSocketOpened,
  reportActualCodeSurfaceReady,
} from "./codeBridge";

const previousWindow = globalThis.window;

afterEach(() => {
  __resetCodeBridgeForTests();
  Object.assign(globalThis, { window: previousWindow });
});

function installWindow(postMessage: (message: unknown) => Promise<unknown>): JSDOM {
  const dom = new JSDOM("<!doctype html><html><body></body></html>", {
    url: "cmux-code://app/index.html",
  });
  Object.defineProperty(dom.window, "webkit", {
    configurable: true,
    value: { messageHandlers: { cmuxCode: { postMessage } } },
  });
  Object.assign(globalThis, { window: dom.window });
  return dom;
}

describe("Code WebView bridge", () => {
  test("mounts the native sidecar once", async () => {
    const messages: unknown[] = [];
    const dom = installWindow(async (message) => {
      messages.push(message);
      return { ok: true };
    });

    await Promise.all([ensureCodeMounted(), ensureCodeMounted(), ensureCodeMounted()]);

    expect(messages).toEqual([{ type: "mount" }]);
    dom.window.close();
  });

  test("routes local fetches through the native handler", async () => {
    const messages: unknown[] = [];
    const dom = installWindow(async (message) => {
      messages.push(message);
      return {
        bodyBase64: btoa("ready"),
        headers: { "Content-Type": "text/plain" },
        status: 200,
        statusText: "OK",
      };
    });
    let browserFetchCount = 0;
    const bridgedFetch = installNativeFetch(async () => {
      browserFetchCount += 1;
      return new Response("browser");
    });

    const response = await bridgedFetch("https://cmux-code.invalid/api/test", {
      body: "hello",
      headers: { "Content-Type": "text/plain" },
      method: "POST",
    });

    expect(await response.text()).toBe("ready");
    expect(browserFetchCount).toBe(0);
    expect(messages).toHaveLength(1);
    expect(messages[0]).toMatchObject({
      type: "fetch",
      request: {
        bodyBase64: btoa("hello"),
        method: "POST",
        url: "https://cmux-code.invalid/api/test",
      },
    });
    dom.window.close();
  });

  test("leaves unrelated fetches on the browser transport", async () => {
    const dom = installWindow(async () => {
      throw new Error("Native bridge should not receive this request");
    });
    const bridgedFetch = installNativeFetch(async () => new Response("browser"));

    const response = await bridgedFetch("https://example.com/");

    expect(await response.text()).toBe("browser");
    dom.window.close();
  });

  test("routes only local sockets through the native handler", async () => {
    const messages: unknown[] = [];
    const dom = installWindow(async (message) => {
      messages.push(message);
      return { ok: true };
    });
    const browserSocketURLs: string[] = [];
    class BrowserWebSocketStub {
      static readonly CONNECTING = 0;
      static readonly OPEN = 1;
      static readonly CLOSING = 2;
      static readonly CLOSED = 3;

      constructor(url: string | URL) {
        browserSocketURLs.push(String(url));
      }
    }
    const BridgedWebSocket = installNativeWebSocket(
      BrowserWebSocketStub as unknown as typeof WebSocket,
    );

    const localSocket = new BridgedWebSocket("wss://cmux-code.invalid/api/events");
    new BridgedWebSocket("wss://example.com/events");
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(browserSocketURLs).toEqual(["wss://example.com/events"]);
    expect(messages[0]).toEqual({ type: "mount" });
    expect(messages[1]).toMatchObject({
      type: "websocketOpen",
      url: "wss://cmux-code.invalid/api/events",
    });

    localSocket.close();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(messages[2]).toMatchObject({ type: "websocketClose" });
    dom.window.close();
  });

  test("keeps real credentials out of the renderer bootstrap", async () => {
    const messages: unknown[] = [];
    const dom = installWindow(async (message) => {
      messages.push(message);
      return { ok: true };
    });
    const desktopBridge = createDesktopBridge();

    const token = await desktopBridge.getLocalEnvironmentBearerToken();
    const [bootstrap] = desktopBridge.getLocalEnvironmentBootstraps();

    expect(token).toBe("cmux-native");
    expect(bootstrap).not.toHaveProperty("bootstrapToken");
    expect(bootstrap?.httpBaseUrl).toBe("https://cmux-code.invalid/");
    expect(messages).toEqual([{ type: "mount" }]);
    dom.window.close();
  });

  test("reports readiness only after the actual connected client renders", async () => {
    const messages: unknown[] = [];
    const dom = installWindow(async (message) => {
      messages.push(message);
      return { ok: true };
    });
    dom.window.document.body.innerHTML = `
      <div id="root">
        <main data-slot="sidebar-wrapper">
          <div contenteditable="true" role="textbox"></div>
        </main>
      </div>
    `;

    installCodeBridge();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(messages).toEqual([{ type: "mount" }]);
    expect(reportActualCodeSurfaceReady()).toBe(false);

    markNativeCodeSocketOpened();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(messages).toEqual([{ type: "mount" }, { type: "ready" }]);
    expect(reportActualCodeSurfaceReady()).toBe(false);
    dom.window.close();
  });

  test("never treats duplicate static markup as actual client readiness", async () => {
    const messages: unknown[] = [];
    const dom = installWindow(async (message) => {
      messages.push(message);
      return { ok: true };
    });
    dom.window.document.body.innerHTML = `
      <main><form><textarea></textarea></form></main>
      <div id="root"></div>
    `;

    installCodeBridge();
    markNativeCodeSocketOpened();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(messages).toEqual([{ type: "mount" }]);
    dom.window.close();
  });
});
