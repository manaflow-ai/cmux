/**
 * Which remote desktop transport a devbox desktop serves
 * (plans/cmux-next/remote-desktop-DESIGN.md, migration step M1).
 *
 * - `novnc` (the default, unchanged): TigerVNC with noVNC through websockify on
 *   6901, opened as a web page (services/vms/images/desktop.ts).
 * - `screen`: the cmux-screen host (remote-desktop-v2.md: WebRTC media,
 *   signaling as a WebSocket on port 4180, RD2-4), opened as a native
 *   `remote_view` tab. Default off: a machine changes only when the operator
 *   sets `CMUX_VM_DESKTOP_TRANSPORT=screen`. The image does not run the
 *   cmux-screen host yet (step M2), so the switch stays off in production.
 */
import { DEVBOX_DESKTOP_DISPLAY, DEVBOX_DESKTOP_NOVNC_PORT, devboxDesktopBaseUrl, devboxDesktopOpenUrl } from "./desktop";

export type DesktopTransport = "novnc" | "screen";

/** The environment variable the VM service reads; only the exact value `screen` turns it on. */
export const DESKTOP_TRANSPORT_ENV = "CMUX_VM_DESKTOP_TRANSPORT";

/** The cmux-screen host's signaling WebSocket (remote-desktop-v2.md RD2-4). */
export const DEVBOX_DESKTOP_SCREEN_SIGNAL_PORT = 4180;

/** What a pane opens for a machine's desktop. */
export type DesktopEndpoint = {
  readonly transport: DesktopTransport;
  /** The guest port the desktop listens on. */
  readonly port: number;
  /** The bare origin at the private address (a web origin, or the signaling WebSocket). */
  readonly url: string;
  /** What the app navigates to: the noVNC page, or a `cmux://remote-view` tab. */
  readonly openUrl: string;
};

/** The transport for a raw setting value; anything but `screen` is the default. */
export function resolveDesktopTransport(value: string | undefined): DesktopTransport {
  return value?.trim() === "screen" ? "screen" : "novnc";
}

/** The guest port that carries the desktop under `transport`. */
export function desktopListenPort(transport: DesktopTransport): number {
  return transport === "screen" ? DEVBOX_DESKTOP_SCREEN_SIGNAL_PORT : DEVBOX_DESKTOP_NOVNC_PORT;
}

/** The desktop endpoint at a private address (an IPv6 literal may come bracketed or bare). */
export function desktopEndpoint(transport: DesktopTransport, address: string): DesktopEndpoint {
  if (transport === "novnc") {
    return {
      transport,
      port: DEVBOX_DESKTOP_NOVNC_PORT,
      url: devboxDesktopBaseUrl(address),
      openUrl: devboxDesktopOpenUrl(address),
    };
  }
  const bare = address.trim().replace(/^\[(.*)\]$/, "$1");
  const literal = bare.includes(":") ? `[${bare}]` : bare;
  const tab = new URLSearchParams({
    host: bare,
    target: `display${DEVBOX_DESKTOP_DISPLAY}`,
    mode: "view",
    via: "screen",
  });
  return {
    transport,
    port: DEVBOX_DESKTOP_SCREEN_SIGNAL_PORT,
    url: `ws://${literal}:${DEVBOX_DESKTOP_SCREEN_SIGNAL_PORT}/`,
    openUrl: `cmux://remote-view?${tab.toString()}`,
  };
}

/** The guest-side check that the desktop is listening: one `ss`, never a sleep loop. */
export function desktopReadyProbe(transport: DesktopTransport): string {
  return `ss -tln 2>/dev/null | grep -q ':${desktopListenPort(transport)} '`;
}
