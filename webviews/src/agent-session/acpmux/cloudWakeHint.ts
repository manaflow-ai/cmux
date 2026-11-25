/**
 * Wake on intent (v1, hq#21300): tells the host the person focused a Cloud chat, before any key,
 * so a paused machine starts its restore now instead of at the first keystroke.
 *
 * The page only forwards the raw signal (`cloudMachine.wakeHint {v, id, signal}`). Whether it
 * counts, the debounce, the per-machine cap, the hidden setting (`cloud.wakeOnIntent`, default
 * off) and the re-pause of an unused wake are the host's Rust rules (cmux-cloud-handlers
 * `wake_hint`). A host without the method answers unsupported: this page stops sending, and the
 * typing prewarm (cloudTypingPrewarm.ts) works as before.
 */

export const CLOUD_WAKE_HINT_VERSION = 1;

/** The raw signals a page can see. The phone's unlock and the Mac's terminal open come from their shells. */
export type CloudWakeSignal = "focus";

export type CloudWakeHintPort = {
  call(method: "cloudMachine.wakeHint", params: { v: number; id: string; signal: CloudWakeSignal }): Promise<unknown>;
};

function unsupported(error: unknown): boolean {
  const code = (error as { code?: unknown } | null)?.code;
  return code === "native.invalid_request" || code === "unsupported";
}

export class CloudWakeHint {
  private hostLacksIt = false;

  constructor(private readonly port: CloudWakeHintPort) {}

  /** The person showed intent toward `machineID`'s chat. Fire and forget: never holds the page. */
  signal(machineID: string | undefined, signal: CloudWakeSignal = "focus"): void {
    if (!machineID || this.hostLacksIt) return;
    let pending: Promise<unknown>;
    try {
      pending = this.port.call("cloudMachine.wakeHint", { v: CLOUD_WAKE_HINT_VERSION, id: machineID, signal });
    } catch (error) {
      if (unsupported(error)) this.hostLacksIt = true;
      return;
    }
    void pending.then(undefined, (error: unknown) => {
      if (unsupported(error)) this.hostLacksIt = true;
    });
  }
}
