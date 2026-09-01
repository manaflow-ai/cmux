import { describe, expect, test } from "bun:test";
import {
  desktopUpstreamUrl,
  desktopWrapperUrl,
  isAllowedDesktopUpstreamHost,
} from "../services/vms/desktopWrapper";

describe("desktop upstream host allowlist", () => {
  test("branded and gateway preview hosts pass", () => {
    expect(isAllowedDesktopUpstreamHost("tidy-heron-6901.vm.cmux.sh")).toBe(true);
    expect(isAllowedDesktopUpstreamHost("noble-wren-cmux.preview.bl.run")).toBe(true);
  });

  test("anything else fails closed", () => {
    expect(isAllowedDesktopUpstreamHost("evil.example.com")).toBe(false);
    expect(isAllowedDesktopUpstreamHost("vm.cmux.sh")).toBe(false);
    expect(isAllowedDesktopUpstreamHost("x.vm.cmux.sh.evil.com")).toBe(false);
    expect(isAllowedDesktopUpstreamHost("a.vm.cmux.sh:8443")).toBe(false);
    expect(isAllowedDesktopUpstreamHost("user@a.vm.cmux.sh")).toBe(false);
    expect(isAllowedDesktopUpstreamHost("")).toBe(false);
    expect(isAllowedDesktopUpstreamHost(null)).toBe(false);
  });
});

describe("wrapper URL (what people see and keep)", () => {
  test("carries cmux_token on our origin, never the gateway parameter", () => {
    const url = desktopWrapperUrl({
      origin: "http://localhost:3777",
      vmId: "tidy-heron",
      upstreamUrl: "https://tidy-heron-6901.vm.cmux.sh",
      token: "abc123def456",
      expiresAtMs: 1_800_000_000_000,
    });
    expect(url).toBe(
      "http://localhost:3777/vm/desktop/tidy-heron?cmux_token=abc123def456&host=tidy-heron-6901.vm.cmux.sh&exp=1800000000000",
    );
    expect(url).not.toContain("bl_preview_token");
  });

  test("refuses non-https or unallowed upstreams", () => {
    expect(desktopWrapperUrl({
      origin: "https://cmux.com",
      vmId: "x",
      upstreamUrl: "http://tidy-heron-6901.vm.cmux.sh",
      token: "abc123def456",
    })).toBeNull();
    expect(desktopWrapperUrl({
      origin: "https://cmux.com",
      vmId: "x",
      upstreamUrl: "https://evil.example.com",
      token: "abc123def456",
    })).toBeNull();
  });
});

describe("upstream URL (where the wrapper sends the pane)", () => {
  test("uses the gateway parameter and forwards only display options", () => {
    const url = desktopUpstreamUrl({
      host: "tidy-heron-6901.vm.cmux.sh",
      token: "abc123def456",
      params: {
        cmux_token: "abc123def456",
        host: "tidy-heron-6901.vm.cmux.sh",
        exp: "1800000000000",
        autoconnect: "1",
        resize: "remote",
        reconnect: "1",
        reconnect_delay: "2000",
        evil: "1",
      },
    });
    expect(url).toContain("bl_preview_token=abc123def456");
    expect(url).toContain("autoconnect=1");
    expect(url).toContain("resize=remote");
    expect(url).toContain("reconnect=1");
    expect(url).toContain("reconnect_delay=2000");
    expect(url).not.toContain("evil");
    expect(url).not.toContain("cmux_token");
    expect(url).not.toContain("exp=");
  });

  test("rejects bad hosts and malformed tokens", () => {
    expect(desktopUpstreamUrl({ host: "evil.example.com", token: "abc123def456", params: {} })).toBeNull();
    expect(desktopUpstreamUrl({ host: "a-1.vm.cmux.sh", token: "", params: {} })).toBeNull();
    expect(desktopUpstreamUrl({ host: "a-1.vm.cmux.sh", token: "bad token!", params: {} })).toBeNull();
  });
});
