// Dev-only demo: connect to a pane protocol provider over WebSocket and call cmux.git.status.
// Strings here are developer diagnostics in a page that never ships, so they are not localized.

import { connectWebSocket } from "../adapters/websocket";
import { createClient } from "../generated/client";
import { schema } from "../generated/validators";
import { Session } from "../session";

const params = new URLSearchParams(location.hash.slice(1));
const wsUrl = params.get("ws");
const token = params.get("token") ?? "";
const cwd = params.get("cwd") ?? "";
// Keep the token out of history once read.
history.replaceState(null, "", location.pathname + location.search);

const log = document.querySelector<HTMLPreElement>("#log")!;
const button = document.querySelector<HTMLButtonElement>("#run")!;

function print(text: string, error = false): void {
  const line = document.createElement("div");
  line.textContent = text;
  if (error) line.className = "err";
  log.append(line);
}

async function main(): Promise<void> {
  if (!wsUrl) {
    print("missing #ws=<url> in the fragment", true);
    button.disabled = true;
    return;
  }
  print(`connecting to ${wsUrl}`);
  const transport = await connectWebSocket({ url: wsUrl, token });
  const session = new Session(transport, {
    role: "client",
    schema,
    onProtocolError: (error) => print(`protocol error: ${error.message}`, true),
  });
  session.onClose((error) => print(`closed: ${error.message}`, true));
  const client = createClient(session);
  const run = async () => {
    const started = performance.now();
    try {
      const status = await client.cmux.git.status({ cwd });
      print(`ok in ${(performance.now() - started).toFixed(1)} ms\n${JSON.stringify(status, null, 2)}`);
    } catch (error) {
      const e = error as { code?: string; message?: string };
      print(`err ${e.code ?? ""}: ${e.message ?? String(error)}`, true);
    }
  };
  button.addEventListener("click", () => void run());
  await run();
}

main().catch((error: unknown) => print(`failed: ${(error as Error).message ?? String(error)}`, true));
