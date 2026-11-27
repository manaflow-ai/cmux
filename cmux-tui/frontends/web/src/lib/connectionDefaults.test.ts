import { describe, expect, it } from "vitest";
import { initialConnectionConfig } from "./connectionDefaults";

const remembered = { getItem: () => "ws://127.0.0.1:7681" };

describe("initialConnectionConfig", () => {
  it("connects a page the daemon served to that same origin, over a remembered URL", () => {
    const config = initialConnectionConfig(
      {
        hostname: "127.0.0.1",
        host: "127.0.0.1:7690",
        protocol: "http:",
        pathname: "/pages/web/",
        search: "",
        hash: "#token=abc",
      },
      remembered,
    );
    expect(config).toEqual({ url: "ws://127.0.0.1:7690/", token: "abc", servedByDaemon: true });
  });

  it("uses wss behind a TLS proxy", () => {
    const config = initialConnectionConfig({
      hostname: "vm.example.ts.net",
      host: "vm.example.ts.net:8443",
      protocol: "https:",
      pathname: "/pages/web/index.html",
      search: "",
      hash: "",
    });
    expect(config.url).toBe("wss://vm.example.ts.net:8443/");
  });

  it("keeps the dev server default and a remembered URL elsewhere", () => {
    const location = {
      hostname: "localhost",
      host: "localhost:5173",
      protocol: "http:",
      pathname: "/",
      search: "",
      hash: "",
    };
    expect(initialConnectionConfig(location).servedByDaemon).toBe(false);
    expect(initialConnectionConfig(location).url).toBe("ws://127.0.0.1:7681");
    expect(initialConnectionConfig(location, { getItem: () => "ws://10.0.0.2:9000" }).url).toBe("ws://10.0.0.2:9000");
  });

  // The daemon's page CSP admits only its own origin, so another ?ws= target
  // stays a manual Connect, never an automatic one.
  it("lets ?ws= win over the serving daemon without connecting on load", () => {
    const config = initialConnectionConfig({
      hostname: "127.0.0.1",
      host: "127.0.0.1:7690",
      protocol: "http:",
      pathname: "/pages/web/",
      search: "?ws=ws://127.0.0.1:9999",
      hash: "#token=abc",
    });
    expect(config.url).toBe("ws://127.0.0.1:9999");
    expect(config.servedByDaemon).toBe(false);
  });
});
