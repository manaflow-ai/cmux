// What the web host's page opens at its address (main.ts): one chat, or nothing and why. Apart from
// main.ts so it is read without mounting the pane (test/web-host-route.test.ts).
import { devHostParams } from "../dev-host/host";
import { parseWebRoute, type WebRoute } from "./route";

/// What the page does at `address` (its path and query) with the fragment `hash`: mount the pane on
/// one chat, or show why it opens nothing.
export type WebHostStart =
  | { open: "chat"; route: Extract<WebRoute, { kind: "agent" }> }
  | { open: "nothing"; reason: string };

export function webHostStart(address: string, hash: string): WebHostStart {
  const parsed = parseWebRoute(address);
  if (!parsed.ok) return { open: "nothing", reason: `This address names no chat (${parsed.error}).` };
  if (parsed.route.kind === "workspace") return { open: "nothing", reason: "Workspaces don't open on the web yet." };
  if (!devHostParams(hash)) return { open: "nothing", reason: "No connection to a machine was given." };
  return { open: "chat", route: parsed.route };
}
