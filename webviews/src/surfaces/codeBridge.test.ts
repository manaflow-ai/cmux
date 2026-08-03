import { afterEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  __resetCodeBridgeForTests,
  activateCodeSurface,
  createDesktopBridge,
  dismissBootShellWhenAppRenders,
  ensureCodeMounted,
  finishCodeDocumentBootstrap,
  installNativeFetch,
  installNativeWebSocket,
  loadCodeRuntimeAssets,
  markNativeCodeSocketOpened,
  prepareInstantCodeSurface,
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

  test("keeps the static shell until the app layout renders", () => {
    const dom = installWindow(async () => ({ ok: true }));
    dom.window.document.body.innerHTML = `
      <div id="boot-shell"><textarea id="cmux-code-instant-draft">keep this</textarea></div>
      <div id="root"></div>
    `;

    expect(dismissBootShellWhenAppRenders()).toBe(false);
    expect(dom.window.document.getElementById("boot-shell")).not.toBeNull();

    dom.window.document.getElementById("root")?.append(
      Object.assign(dom.window.document.createElement("div"), {
        innerHTML:
          '<main data-slot="sidebar-wrapper"><div contenteditable="true" role="textbox"></div></main>',
      }),
    );
    expect(dismissBootShellWhenAppRenders()).toBe(true);
    expect(dom.window.document.getElementById("boot-shell")).toBeNull();
    expect(
      dom.window.document.querySelector<HTMLElement>('#root [role="textbox"]')?.textContent,
    ).toBe("keep this");
    dom.window.close();
  });

  test("keeps the complete static frame over a transient connection alert", () => {
    const dom = installWindow(async () => ({ ok: true }));
    dom.window.document.body.innerHTML = `
      <div id="boot-shell"><textarea id="cmux-code-instant-draft"></textarea></div>
      <div id="root">
        <main data-slot="sidebar-wrapper">
          <div contenteditable="true" role="textbox"></div>
          <div role="alert"><button disabled>Connecting</button></div>
        </main>
      </div>
    `;

    expect(dismissBootShellWhenAppRenders()).toBe(false);
    expect(dom.window.document.getElementById("boot-shell")).not.toBeNull();

    dom.window.document.querySelector('[role="alert"]')?.remove();
    expect(dismissBootShellWhenAppRenders()).toBe(true);
    expect(dom.window.document.getElementById("boot-shell")).toBeNull();
    dom.window.close();
  });

  test("waits for the native connection before retiring an otherwise complete frame", () => {
    const dom = installWindow(async () => ({ ok: true }));
    dom.window.document.body.innerHTML = `
      <div id="boot-shell"><textarea id="cmux-code-instant-draft"></textarea></div>
      <div id="root">
        <main data-slot="sidebar-wrapper">
          <div contenteditable="true" role="textbox"></div>
        </main>
      </div>
    `;

    expect(dismissBootShellWhenAppRenders(false, true)).toBe(false);
    expect(dom.window.document.getElementById("boot-shell")).not.toBeNull();

    markNativeCodeSocketOpened();
    expect(dismissBootShellWhenAppRenders(false, true)).toBe(true);
    expect(dom.window.document.getElementById("boot-shell")).toBeNull();
    dom.window.close();
  });

  test("renders a localized usable first frame without activating the runtime", () => {
    const dom = new JSDOM(
      `<!doctype html><html><body>
        <main id="boot-shell">
          <h1 data-cmux-string="headline">fallback</h1>
          <form><textarea id="cmux-code-instant-draft" data-cmux-placeholder="prompt"></textarea></form>
        </main>
        <div id="root"></div>
        <script type="application/x-cmux-code-module" data-cmux-code-main="/assets/main.js"></script>
      </body></html>`,
      { url: "cmux-code://app/index.html" },
    );
    Object.assign(dom.window, {
      __cmuxCodeStaticBootstrap: {
        strings: { headline: "Start building", prompt: "Describe a task" },
      },
    });
    Object.assign(globalThis, { window: dom.window });

    expect(prepareInstantCodeSurface()).toBe(true);
    expect(dom.window.document.querySelector("h1")?.textContent).toBe("Start building");
    expect(dom.window.document.querySelector("textarea")?.placeholder).toBe("Describe a task");
    expect(dom.window.document.querySelector("script[data-cmux-code-runtime]")).toBeNull();
    dom.window.close();
  });

  test("loads heavy runtime assets only after native activation", async () => {
    const messages: unknown[] = [];
    const dom = installWindow(async (message) => {
      messages.push(message);
      return { ok: true };
    });
    dom.window.document.head.innerHTML = `
      <link data-cmux-code-stylesheet href="/assets/main.css">
      <link data-cmux-code-modulepreload href="/assets/editor.js">
      <script type="application/x-cmux-code-module" data-cmux-code-main="/assets/main.js"></script>
    `;

    expect(dom.window.document.querySelector("script[data-cmux-code-runtime]")).toBeNull();
    activateCodeSurface();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(messages).toEqual([{ type: "mount" }]);
    expect(
      dom.window.document.querySelector<HTMLLinkElement>("link[data-cmux-code-stylesheet]")?.rel,
    ).toBe("stylesheet");
    expect(
      dom.window.document.querySelector<HTMLLinkElement>("link[data-cmux-code-modulepreload]")
        ?.rel,
    ).toBe("modulepreload");
    expect(dom.window.document.querySelectorAll("script[data-cmux-code-runtime]")).toHaveLength(1);
    expect(loadCodeRuntimeAssets()).toBe(false);
    dom.window.close();
  });

  test("cold document bootstrap activates the runtime marker after parsing", async () => {
    const messages: unknown[] = [];
    const dom = installWindow(async (message) => {
      messages.push(message);
      return { ok: true };
    });
    dom.window.document.head.innerHTML = `
      <script type="application/x-cmux-code-module" data-cmux-code-main="/assets/main.js"></script>
    `;
    dom.window.document.body.innerHTML = `
      <main id="boot-shell"><form><textarea id="cmux-code-instant-draft"></textarea></form></main>
      <div id="root"></div>
    `;
    dom.window.__cmuxCodeAutoActivate = true;

    finishCodeDocumentBootstrap();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(messages).toEqual([{ type: "mount" }]);
    expect(dom.window.document.querySelectorAll("script[data-cmux-code-runtime]")).toHaveLength(1);
    dom.window.close();
  });
});
