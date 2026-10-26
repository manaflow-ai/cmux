/// A refused handshake that offers Restart acpmux (`details.restartAcpmux`).
export function offersAcpmuxRestart(error: unknown): boolean {
  const details = (error as { details?: unknown } | null)?.details;
  return !!details && typeof details === "object" && (details as { restartAcpmux?: unknown }).restartAcpmux === true;
}

export type AcpmuxRestartHooks = {
  cancelRetries(): void;
  changed(restarting: boolean): void;
  connected(): boolean;
  ask(): void;
};

/** Blocks every handshake while the refused daemon is being replaced. */
export class AcpmuxRestartGate {
  private running = false;
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
      // The native operation reports stopped:false or fails; ask again below.
    } finally {
      this.running = false;
      hooks.changed(false);
      if (!hooks.connected()) hooks.ask();
    }
  }
}
