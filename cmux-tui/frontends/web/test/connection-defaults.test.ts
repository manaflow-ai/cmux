import { describe, expect, it } from "vitest";
import { defaultWebSocketUrl, initialConnectionConfig } from "../src/lib/connectionDefaults";

describe("WebSocket URL defaults", () => {
  it("uses the loopback development socket for local hosts", () => {
    expect(defaultWebSocketUrl("localhost")).toBe("ws://127.0.0.1:7681");
    expect(defaultWebSocketUrl("127.0.0.1")).toBe("ws://127.0.0.1:7681");
  });

  it("uses the documented secure port beside a remotely hosted frontend", () => {
    expect(defaultWebSocketUrl("lawrences-macbook-pro-2.tail137216.ts.net"))
      .toBe("wss://lawrences-macbook-pro-2.tail137216.ts.net:8443");
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
});
