import { useEffect, useState } from "react";
import { callNative } from "./callNative";
import { HOST_ERROR_DEADLINE_MS } from "./hostRetry";

/// `acpmux.serviceWait {waitedMs}`: the host's word on the daemon a waiting handshake waits on.
export function askServiceWait(params: { waitedMs: number }): Promise<unknown> {
  return callNative<unknown>("acpmux.serviceWait", params);
}

/// The host's word on the daemon a handshake waits on (`acpmux.serviceWait`): busy (a process
/// listens on the socket, the reply is late), starting (the process runs, its socket does not take
/// connections yet) or down (neither); and whether Restart agent service fits.
export type AgentServiceWait = { state: "busy" | "starting" | "down"; restart: boolean };

/// The `acpmux.serviceWait` reply as the line takes it; undefined for a reply that says nothing
/// (a host that cannot tell, an app before this request) or is malformed.
export function readAgentServiceWait(reply: unknown): AgentServiceWait | undefined {
  if (!reply || typeof reply !== "object") return undefined;
  const { state, restart } = reply as { state?: unknown; restart?: unknown };
  if ((state !== "busy" && state !== "starting" && state !== "down") || typeof restart !== "boolean") return undefined;
  return { state, restart };
}

/// How often the pane asks the host what it sees of the daemon while its waiting line shows. The
/// host's probe is a pid file read and one local socket connect; the verdict is Rust's
/// (cmux-agent-pane-policy service_wait.rs). The page only draws what it is told.
export const SERVICE_WAIT_ASK_MS = 5_000;
/// How long before the line shows the pane asks first.
export const SERVICE_WAIT_LEAD_MS = 1_000;

/// What the host says of the daemon a handshake has waited on since `since` (`Date.now()` time),
/// asked from the moment the waiting line shows (`HOST_ERROR_DEADLINE_MS`) and every
/// `SERVICE_WAIT_ASK_MS` after, until the wait ends. Undefined before the first answer, when no
/// wait runs, or when the host cannot tell (an app before `acpmux.serviceWait`, a remote chat).
export function useAgentServiceWait(
  since: number | undefined,
  ask: (params: { waitedMs: number }) => Promise<unknown>,
): AgentServiceWait | undefined {
  const [said, setSaid] = useState<{ since: number; wait: AgentServiceWait | undefined }>();
  useEffect(() => {
    if (since === undefined) return;
    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const askNow = () => {
      timer = undefined;
      ask({ waitedMs: Math.max(0, Date.now() - since) })
        .then(
          (reply) => readAgentServiceWait(reply),
          () => undefined,
        )
        .then((wait) => {
          if (stopped) return;
          setSaid({ since, wait });
          timer = setTimeout(askNow, SERVICE_WAIT_ASK_MS);
        });
    };
    // A second before the line shows, so its first frame already says busy or down (no Restart
    // drawn and then taken away).
    timer = setTimeout(askNow, Math.max(0, since + HOST_ERROR_DEADLINE_MS - SERVICE_WAIT_LEAD_MS - Date.now()));
    return () => {
      stopped = true;
      if (timer !== undefined) clearTimeout(timer);
    };
  }, [since, ask]);
  return said && said.since === since ? said.wait : undefined;
}
