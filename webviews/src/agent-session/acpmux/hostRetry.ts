import { peerLinkFailure, peerLinkFailureShows } from "./hostLine";

/// A refused handshake that offers Restart acpmux (`details.restartAcpmux`): another binary's
/// daemon holds this app's acpmux socket, and the app may replace it with its own on a click.
export function offersAcpmuxRestart(error: unknown): boolean {
  const details = (error as { details?: unknown } | null)?.details;
  return !!details && typeof details === "object" && (details as { restartAcpmux?: unknown }).restartAcpmux === true;
}

/// A host-owned update handoff or a lost transport is still recovering. A definite host refusal
/// (missing binary, stopped daemon, unsupported machine, untrusted folder) keeps its instructions.
/// Older bridges may omit retryability on socket failures; only errors without an owned code fall
/// back to recovery. Never infer it from the translated message or from the restart gate.
export function hostIsReconnecting(error: unknown): boolean {
  const fields = error as {
    code?: unknown;
    retryable?: unknown;
    details?: { reconnecting?: unknown };
    data?: { retryable?: unknown };
  } | null;
  if (fields?.details?.reconnecting === true) return true;
  // The chat's machine is reconnecting (acpmux `peer_unreachable`/`peer_disconnected`): acpmux
  // reconnects it on its own, and the request was not sent (hostLine.ts).
  if (peerLinkFailure(error)) return true;
  // acpmux marks a refusal a retry clears (`data.retryable`; direct.ts keeps `data` on the error).
  if (fields?.data?.retryable === true) return true;
  if (fields?.code === "native.not_connected" || fields?.code === "native.timed_out") return true;
  if (typeof fields?.retryable === "boolean") return fields.retryable;
  if (typeof fields?.code === "string") return false;
  return fields?.code === undefined;
}

/// A handshake refused because a reply would pass one message (`message.too_large`: a chat
/// whose records together were too large to open, on an acpmux before #28754). Asking again gets
/// the same reply, so the pane never asks on its own; the line's Retry still asks (Leo,
/// 2026-10-31: "this is completely hardlocked bc of message size").
export function hostRefusedTooLarge(error: unknown): boolean {
  return (error as { reason?: unknown } | null)?.reason === "message.too_large";
}

/// How long a pane's handshakes may keep failing while the host is still recovering (an update's
/// handoff, a daemon starting or restarting, a start that lost the lock race) before the pane says
/// so. Until then the pane shows nothing: no card, no header status, no button (Leo, 2026-10-29:
/// "STOP SHOWING FUCKING BULLSHIT ON LOAD"). 25 s: a daemon after an update answered 10 s after the
/// first failed handshake in the logged timeline (#27283), so a recovery past 25 s is a failure.
/// The page's own retries keep running past it, and a connect clears the line.
export const HOST_ERROR_DEADLINE_MS = 25_000;

/// Whether a failed handshake is said (one line above the composer) after the handshakes have been
/// failing for `failingForMs`. A refusal the host cannot recover from by itself (acpmux missing,
/// another build's daemon, a refused chat) is said at once; a recovery only after the deadline.
/// A chat whose machine is unreachable is said only once the person can act (hostLine.ts
/// `peerLinkFailureShows`): never while the machine is slow or restarting, else after two minutes.
export function hostErrorShows(error: unknown, failingForMs: number): boolean {
  const peer = peerLinkFailure(error);
  if (peer) return peerLinkFailureShows(peer, failingForMs);
  return !hostIsReconnecting(error) || failingForMs >= HOST_ERROR_DEADLINE_MS;
}

/// The wait before the next handshake. Looking for a daemon is cheap, so while the host is
/// recovering it is asked again within 2 s and the chat appears soon after the daemon answers (a
/// 30 s cap saw a ready daemon up to 32 s late, #27283's replay); a refusal that waits on the
/// person backs off to 30 s, so a host without a daemon is not asked four times a second.
export function nextRetryDelay(delay: number, recovering: boolean): number {
  return Math.min(delay * 2, recovering ? 2_000 : 30_000);
}

/// What the pane's handshake loop does around a Restart acpmux.
export type AcpmuxRestartHooks = {
  /// Drops the automatic retry waiting to run and a Retry queued behind an attempt in flight.
  cancelRetries(): void;
  /// The card's in-flight state.
  changed(restarting: boolean): void;
  /// Whether a client connected meanwhile (then no second handshake runs).
  connected(): boolean;
  /// Asks the host again now, as Retry does.
  ask(): void;
};

/// The pane's Restart acpmux. While one runs no handshake may start (``mayAsk``): not the
/// automatic retry, not a Retry queued behind an attempt that was in flight, so the old daemon is
/// never asked again while it shuts down. When the restart ends, one handshake runs unless a client
/// connected meanwhile. A second click while one runs does nothing.
export class AcpmuxRestartGate {
  private running = false;

  /// Whether a handshake may start now.
  mayAsk(): boolean {
    return !this.running;
  }

  async run(stop: () => Promise<unknown>, hooks: AcpmuxRestartHooks): Promise<void> {
    if (this.running) return;
    this.running = true;
    hooks.cancelRetries();
    hooks.changed(true);
    try {
      await stop();
    } catch {
      // The app answers `{stopped: false}` or fails; either way the pane asks again below.
    } finally {
      this.running = false;
      hooks.changed(false);
      if (!hooks.connected()) hooks.ask();
    }
  }
}
