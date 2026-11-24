// Settings > Server > This Mac on Your Tailnet: what the card draws for acpmux's tailnet snapshot
// (ops.ts `TailnetState`). Pure, so the card and its tests read the same answer.
import type { TailnetState } from "./ops";

export type TailnetView =
  | { kind: "signedOut" }
  | { kind: "starting" }
  /** Waiting on the browser: `url` is the sign-in page, null until acpmux has one. */
  | { kind: "needsLogin"; url: string | null }
  /** Signed in, waiting for the tailnet's admin to approve this Mac. */
  | { kind: "approval" }
  /** `address` is the MagicDNS name and the first IPv4 address, whichever acpmux reported. */
  | { kind: "signedIn"; address: string }
  | { kind: "error"; message: string };

/** Only an https page from acpmux is offered as the sign-in link. */
function signInURL(url: string | undefined): string | null {
  if (!url) return null;
  try {
    return new URL(url).protocol === "https:" ? url : null;
  } catch {
    return null;
  }
}

export function tailnetView(state: TailnetState): TailnetView {
  switch (state.state) {
    case "starting":
      return { kind: "starting" };
    case "needs_login":
      return { kind: "needsLogin", url: signInURL(state.browse_to_url) };
    case "needs_machine_auth":
      return { kind: "approval" };
    case "running": {
      const ip = state.ips?.find((address) => !address.includes(":")) ?? state.ips?.[0];
      return { kind: "signedIn", address: [state.dns_name, ip].filter(Boolean).join(" · ") };
    }
    case "error":
      return { kind: "error", message: state.error ?? "" };
    default:
      // stopped, not_started, no_state, unknown, in_use_other_user: nothing this Mac is signed in to.
      return { kind: "signedOut" };
  }
}

/** A sign-in that waits on something outside this page (the browser, the tailnet's admin). */
export function tailnetWaits(view: TailnetView): boolean {
  return view.kind === "needsLogin" || view.kind === "approval" || view.kind === "starting";
}

/** After Sign In, acpmux answers before its node publishes where it got to (the sign-in page reaches
 * acpmux on the node's own bus): true while that answer is still on its way, so the card reads again. */
export function tailnetSettling(state: TailnetState): boolean {
  return (
    state.state === "starting" ||
    state.state === "stopped" ||
    state.state === "no_state" ||
    (state.state === "needs_login" && !state.browse_to_url)
  );
}

/** The card's reads after Sign In: 0.25 s, doubling, the last at 4 s (about 8 s in all), then it stops. */
export const TAILNET_SETTLE_WAITS_MS = [250, 500, 1000, 2000, 4000] as const;
