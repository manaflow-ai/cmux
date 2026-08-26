import { describe, expect, test } from "bun:test";
import {
  desktopHostMatchesVm,
  desktopIframeUrl,
  desktopSessionFromInputs,
  desktopWrapperUrl,
  isAllowedDesktopUpstreamHost,
  upgradedLegacyWrapperUrl,
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

describe("branded host to machine binding", () => {
  test("a vm.cmux.sh host must name the machine", () => {
    expect(desktopHostMatchesVm("tidy-heron-6901.vm.cmux.sh", "tidy-heron")).toBe(true);
    expect(desktopHostMatchesVm("tidy-heron-6901.vm.cmux.sh", "other-machine")).toBe(false);
    expect(desktopHostMatchesVm("tidy-heron-6901.vm.cmux.sh", "")).toBe(false);
    // The label must be exactly "<machine>-<port>": a machine named "tidy"
    // cannot claim tidy-heron's screen through the shared prefix.
    expect(desktopHostMatchesVm("tidy-heron-6901.vm.cmux.sh", "tidy")).toBe(false);
  });

  test("opaque bl.run hash hosts carry no machine name, so only the allowlist applies", () => {
    expect(desktopHostMatchesVm("a1b2c3d4.us-pdx-1.preview.bl.run", "tidy-heron")).toBe(true);
  });
});

describe("wrapper URL (what people see and keep)", () => {
  test("carries the session in the fragment on our origin, never in the query", () => {
    const url = desktopWrapperUrl({
      origin: "http://localhost:3777",
      vmId: "tidy-heron",
      upstreamUrl: "https://tidy-heron-6901.vm.cmux.sh",
      token: "abc123def456",
      expiresAtMs: 1_800_000_000_000,
    });
    expect(url).toBe(
      "http://localhost:3777/vm/desktop/tidy-heron#cmux_token=abc123def456&host=tidy-heron-6901.vm.cmux.sh&exp=1800000000000",
    );
    expect(url).not.toContain("bl_preview_token");
    expect(new URL(url!).search).toBe("");
  });

  test("refuses non-https, unallowed, or mismatched-machine upstreams", () => {
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
    expect(desktopWrapperUrl({
      origin: "https://cmux.com",
      vmId: "other-machine",
      upstreamUrl: "https://tidy-heron-6901.vm.cmux.sh",
      token: "abc123def456",
    })).toBeNull();
  });
});

describe("session parsing (fragment first, legacy query as fallback)", () => {
  test("reads the fragment, including display params a caller appended with a bare &", () => {
    const session = desktopSessionFromInputs({
      // The mac CLI appends display options to openUrl with a bare "&", which
      // lands inside the fragment.
      fragment:
        "#cmux_token=abc123def456&host=tidy-heron-6901.vm.cmux.sh&exp=1800000000000" +
        "&autoconnect=1&resize=remote&reconnect=1&reconnect_delay=2000&evil=1",
      legacyQuery: {},
    });
    expect(session.token).toBe("abc123def456");
    expect(session.host).toBe("tidy-heron-6901.vm.cmux.sh");
    expect(session.expiresAtMs).toBe(1_800_000_000_000);
    expect(session.displayParams).toEqual({
      autoconnect: "1",
      resize: "remote",
      reconnect: "1",
      reconnect_delay: "2000",
    });
  });

  test("legacy query URLs still resolve, and the fragment wins field by field", () => {
    const legacyOnly = desktopSessionFromInputs({
      fragment: "",
      legacyQuery: {
        cmux_token: "legacy0token",
        host: "tidy-heron-6901.vm.cmux.sh",
        exp: "1700000000000",
        autoconnect: "1",
      },
    });
    expect(legacyOnly.token).toBe("legacy0token");
    expect(legacyOnly.host).toBe("tidy-heron-6901.vm.cmux.sh");
    expect(legacyOnly.expiresAtMs).toBe(1_700_000_000_000);
    expect(legacyOnly.displayParams.autoconnect).toBe("1");

    const mixed = desktopSessionFromInputs({
      fragment: "#cmux_token=fragment0token",
      legacyQuery: { cmux_token: "legacy0token", host: "tidy-heron-6901.vm.cmux.sh" },
    });
    expect(mixed.token).toBe("fragment0token");
    expect(mixed.host).toBe("tidy-heron-6901.vm.cmux.sh");
  });

  test("missing everything yields an empty session", () => {
    const session = desktopSessionFromInputs({ fragment: "", legacyQuery: {} });
    expect(session.token).toBe("");
    expect(session.host).toBe("");
    expect(session.expiresAtMs).toBeNull();
    expect(session.displayParams).toEqual({});
  });
});

describe("legacy URL upgrade (token scrubbed out of the query)", () => {
  test("moves query params into the fragment and empties the query", () => {
    const upgraded = upgradedLegacyWrapperUrl(
      "https://cmux.com/vm/desktop/tidy-heron?cmux_token=abc123def456&host=tidy-heron-6901.vm.cmux.sh&exp=1800000000000&autoconnect=1",
    );
    expect(upgraded).toBe(
      "https://cmux.com/vm/desktop/tidy-heron#cmux_token=abc123def456&host=tidy-heron-6901.vm.cmux.sh&exp=1800000000000&autoconnect=1",
    );
  });

  test("existing fragment values win over the legacy query", () => {
    const upgraded = upgradedLegacyWrapperUrl(
      "https://cmux.com/vm/desktop/tidy-heron?cmux_token=old0token#cmux_token=new0token",
    );
    expect(upgraded).toBe("https://cmux.com/vm/desktop/tidy-heron#cmux_token=new0token");
  });

  test("returns null when there is nothing to scrub", () => {
    expect(upgradedLegacyWrapperUrl("https://cmux.com/vm/desktop/tidy-heron#cmux_token=x")).toBeNull();
    expect(upgradedLegacyWrapperUrl("https://cmux.com/vm/desktop/tidy-heron?autoconnect=1")).toBeNull();
    expect(upgradedLegacyWrapperUrl("not a url")).toBeNull();
  });
});

describe("iframe URL (internal to the wrapper)", () => {
  test("uses the gateway parameter and forwards only display options", () => {
    const url = desktopIframeUrl({
      host: "tidy-heron-6901.vm.cmux.sh",
      token: "abc123def456",
      vmId: "tidy-heron",
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

  test("rejects bad hosts, malformed tokens, and machine-mismatched branded hosts", () => {
    expect(desktopIframeUrl({ host: "evil.example.com", token: "abc123def456", params: {} })).toBeNull();
    expect(desktopIframeUrl({ host: "a-1.vm.cmux.sh", token: "", params: {} })).toBeNull();
    expect(desktopIframeUrl({ host: "a-1.vm.cmux.sh", token: "bad token!", params: {} })).toBeNull();
    expect(
      desktopIframeUrl({
        host: "tidy-heron-6901.vm.cmux.sh",
        token: "abc123def456",
        vmId: "other-machine",
        params: {},
      }),
    ).toBeNull();
  });
});
