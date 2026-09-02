import { describe, expect, it } from "vitest";
import {
  defaultMacWebSocketUrl,
  defaultWebSocketUrl,
  initialConnectionConfig,
  rememberWebSocketUrl,
} from "../src/lib/connectionDefaults";

describe("WebSocket URL defaults", () => {
  it("uses the loopback development socket for local hosts", () => {
    expect(defaultWebSocketUrl("localhost")).toBe("ws://127.0.0.1:7681");
    expect(defaultWebSocketUrl("127.0.0.1")).toBe("ws://127.0.0.1:7681");
  });

  it("uses the documented secure port beside a remotely hosted frontend", () => {
    expect(defaultWebSocketUrl("lawrences-macbook-pro-2.tail137216.ts.net"))
      .toBe("wss://lawrences-macbook-pro-2.tail137216.ts.net:8443");
  });

  it("uses the bridge path for local and privately proxied Mac runtimes", () => {
    expect(defaultMacWebSocketUrl("localhost")).toBe("ws://127.0.0.1:7683/cmux");
    expect(defaultMacWebSocketUrl("my-mac.tailnet.ts.net"))
      .toBe("wss://my-mac.tailnet.ts.net/cmux");
    expect(defaultMacWebSocketUrl("my-mac.tailnet.ts.net", "8443"))
      .toBe("wss://my-mac.tailnet.ts.net:8443/cmux");
    expect(defaultMacWebSocketUrl("my-mac.tailnet.ts.net", "443"))
      .toBe("wss://my-mac.tailnet.ts.net/cmux");
  });

  it("takes the socket URL from the query and the token only from the fragment", () => {
    const storage = { getItem: () => "wss://remembered.test:8443" };
    const location = {
      hostname: "remote.test",
      search: "?ws=ws%3A%2F%2F127.0.0.1%3A7682&token=query-secret",
      hash: "#token=fragment-secret",
    };
    expect(initialConnectionConfig(
      location,
      storage,
    )).toEqual({ url: "ws://127.0.0.1:7682", token: "fragment-secret" });
  });

  it("keeps Mac and TUI remembered endpoints in separate slots", () => {
    const values = new Map<string, string>();
    const storage = {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: (key: string, value: string) => values.set(key, value),
    };
    rememberWebSocketUrl("ws://127.0.0.1:7683/cmux", storage, "mac");
    rememberWebSocketUrl("ws://127.0.0.1:7681", storage, "tui");
    expect(initialConnectionConfig({ hostname: "localhost", search: "", hash: "" }, storage, "mac").url)
      .toBe("ws://127.0.0.1:7683/cmux");
    expect(initialConnectionConfig({ hostname: "localhost", search: "", hash: "" }, storage, "tui").url)
      .toBe("ws://127.0.0.1:7681");
  });

  it("preserves the hosted page port for a Mac bridge default", () => {
    expect(initialConnectionConfig({
      hostname: "my-mac.tailnet.ts.net",
      port: "8443",
      search: "",
      hash: "",
    }, undefined, "mac").url).toBe("wss://my-mac.tailnet.ts.net:8443/cmux");
  });
});
