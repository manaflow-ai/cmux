// The web client's agent pane as a static site (cmuxterm-hq docs/rfd/0083-cmux-web-client.md, step 3):
// scripts/cmux-next/build-web-host.sh bundles this entry in place of the app's (acpmux/main.tsx).
// The page's path is its route (route.ts, held to cmux-tui/crates/cmux-web-route by the shared
// vectors): `/m/<machine>/agent/<harness>/<session>` opens that one chat and no other. A route that
// names no chat opens nothing and says why; a chat its machine lacks shows the pane's unavailable
// state (`sessionMustExist`), never another chat.
//
// The connection is the dev host's for now (`#endpoint=ws://127.0.0.1:…&token=…`, a loopback acpmux
// daemon; dev-host/host.ts): the gateway that carries a remote machine's acpmux comes with the
// web client's transport, a later step.
import { devHostParams, installDevHost } from "../dev-host/host";
import { installBrowserHost } from "../agent-session/acpmux/browser/host";
import { mountAcpmux } from "../agent-session/acpmux/mountModel";
import { webHostStart } from "./start";

function showNothing(reason: string): void {
  const root = document.getElementById("root");
  if (!root) return;
  const line = document.createElement("p");
  line.className = "web-host-refusal";
  line.setAttribute("role", "alert");
  line.textContent = reason;
  root.replaceChildren(line);
}

if (typeof window !== "undefined" && document.getElementById("root")) {
  const start = webHostStart(location.pathname + location.search, location.hash);
  const connection = devHostParams(location.hash);
  if (start.open === "nothing" || !connection) {
    showNothing(start.open === "nothing" ? start.reason : "No connection to a machine was given.");
  } else {
    const machine = start.route.machine;
    installDevHost({
      ...connection,
      sessionId: start.route.session,
      newSession: false,
      sessionMustExist: true,
      ...(machine && "name" in machine ? { machineName: machine.name } : {}),
    });
    installBrowserHost();
    mountAcpmux();
  }
}
