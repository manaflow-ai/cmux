import { describe, expect, test } from "bun:test";
import {
  DESKTOP_TRANSPORT_ENV,
  DEVBOX_DESKTOP_SCREEN_SIGNAL_PORT,
  desktopEndpoint,
  desktopListenPort,
  desktopReadyProbe,
  resolveDesktopTransport,
} from "../services/vms/images/desktopTransport";
import { DEVBOX_DESKTOP_NOVNC_PORT, devboxDesktopOpenUrl } from "../services/vms/images/desktop";

// The desktop transport switch (plans/cmux-next/remote-desktop-DESIGN.md,
// migration step M1): `novnc` (TigerVNC + noVNC + websockify on 6901) stays the
// default; `screen` names the cmux-screen host (WebRTC media, signaling on
// tailnet/overlay port 4180, remote-desktop-v2.md RD2-4). Nothing changes for
// a machine unless CMUX_VM_DESKTOP_TRANSPORT is exactly "screen".

describe("desktop transport switch", () => {
  test("default is noVNC; only the exact value `screen` turns the cmux-screen host on", () => {
    expect(DESKTOP_TRANSPORT_ENV).toBe("CMUX_VM_DESKTOP_TRANSPORT");
    expect(resolveDesktopTransport(undefined)).toBe("novnc");
    expect(resolveDesktopTransport("")).toBe("novnc");
    expect(resolveDesktopTransport("novnc")).toBe("novnc");
    expect(resolveDesktopTransport("screen")).toBe("screen");
    expect(resolveDesktopTransport(" screen ")).toBe("screen");
    // Anything else (typos, other casing, old names) falls back to the default.
    expect(resolveDesktopTransport("Screen")).toBe("novnc");
    expect(resolveDesktopTransport("webrtc")).toBe("novnc");
    expect(resolveDesktopTransport("rd")).toBe("novnc");
  });

  test("listen ports: 6901 for noVNC, 4180 (RD2-4 signaling) for the cmux-screen host", () => {
    expect(DEVBOX_DESKTOP_SCREEN_SIGNAL_PORT).toBe(4180);
    expect(desktopListenPort("novnc")).toBe(DEVBOX_DESKTOP_NOVNC_PORT);
    expect(desktopListenPort("screen")).toBe(4180);
  });

  test("the noVNC endpoint is byte-identical to today's contract", () => {
    expect(desktopEndpoint("novnc", "10.4.0.7")).toEqual({
      transport: "novnc",
      port: 6901,
      url: "http://10.4.0.7:6901/",
      openUrl: devboxDesktopOpenUrl("10.4.0.7"),
    });
  });

  test("the screen endpoint is a signaling WebSocket and a native remote-view tab, never a web page", () => {
    expect(desktopEndpoint("screen", "10.4.0.7")).toEqual({
      transport: "screen",
      port: 4180,
      url: "ws://10.4.0.7:4180/",
      openUrl: "cmux://remote-view?host=10.4.0.7&target=display%3A1&mode=view&via=screen",
    });
    const v6 = desktopEndpoint("screen", "fd00:4::7");
    expect(v6.url).toBe("ws://[fd00:4::7]:4180/");
    expect(new URL(v6.openUrl).searchParams.get("host")).toBe("fd00:4::7");
    expect(desktopEndpoint("screen", "[fd00:4::7]").url).toBe("ws://[fd00:4::7]:4180/");
    // View is the default mode: control stays the person's toggle in the pane.
    expect(new URL(v6.openUrl).searchParams.get("mode")).toBe("view");
  });

  test("the readiness probe checks the transport's own port and never sleeps", () => {
    expect(desktopReadyProbe("novnc")).toBe("ss -tln 2>/dev/null | grep -q ':6901 '");
    expect(desktopReadyProbe("screen")).toBe("ss -tln 2>/dev/null | grep -q ':4180 '");
    for (const transport of ["novnc", "screen"] as const) {
      expect(desktopReadyProbe(transport)).not.toContain("sleep");
    }
  });
});
