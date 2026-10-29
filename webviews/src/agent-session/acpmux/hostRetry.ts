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
  const fields = error as { code?: unknown; retryable?: unknown; details?: { reconnecting?: unknown } } | null;
  if (fields?.details?.reconnecting === true) return true;
  if (fields?.code === "native.not_connected" || fields?.code === "native.timed_out") return true;
  if (typeof fields?.retryable === "boolean") return fields.retryable;
  if (typeof fields?.code === "string") return false;
  return fields?.code === undefined;
}

/// How long a recovery stays neutral before the pane says it failed: a daemon restarting after an
/// update is back within seconds, so a minute of failures is no longer a restart (Leo, 2026-10-29:
/// "why is that still there? it's unnecessary").
export const RECONNECTING_GRACE_MS = 60_000;

/// Whether a failed handshake still shows as Reconnecting… after failing for `failingForMs`.
export function staysReconnecting(error: unknown, failingForMs: number): boolean {
  return hostIsReconnecting(error) && failingForMs < RECONNECTING_GRACE_MS;
}

/// The wait before the next handshake. Looking for a daemon is cheap, so a lost daemon or one
/// that is restarting is asked again within 2 s; only a refusal that waits on the person backs
/// off to 30 s, so a host without a daemon is not asked four times a second.
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
