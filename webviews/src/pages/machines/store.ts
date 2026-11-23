// The Machines section's state owner: the app's snapshot, read once, then replaced by each one the
// `changes` stream carries (the host sends none while the section is hidden). React reads it through
// `useSyncExternalStore`; a read older than a newer snapshot is dropped.
import type { PageClient } from "../shared/pageClient";
import { keptSnapshot } from "./model";
import { MachinesOps, type JoinedDialAnswer, type JoinedDialPhase, type MachinesSnapshot } from "./types";

export interface MachinesState {
  snapshot?: MachinesSnapshot;
  /** The page has no host to ask. */
  unavailable?: boolean;
  /** The row whose native menu is open: its controls stay shown and its button lit. */
  menuOpen?: string;
  /** The joined row whose Remove question is open. */
  confirmRemove?: string;
  /** Rows the person removed: they leave the list in the frame of the click, before the host answers.
   * A row comes back only if the host refused (its caption then says so). */
  removed: ReadonlySet<string>;
  /** Each joined Mac's New Workspace that has not opened yet, by row: what its row says instead of its
   * caption (`JoinedDialPhase`). A row with none shows its caption. */
  dials: Readonly<Record<string, JoinedDialPhase>>;
}

/** How long a row waits, between asks, for the other Mac's person to answer its card: 2 s, then a
 * little longer each time, about three minutes in all. After the last one the row stops asking and
 * says "No answer from…" with Retry. Not now ends the wait at once: nothing asks again until Retry. */
export const DIAL_RECHECK_MS: readonly number[] = [2000, 3000, 5000, 8000, 13000, 20000, 30000, 30000, 30000, 30000];

/** The `unavailable` reasons that mean the other Mac's cmux predates the consent (#43384: an older
 * Mac answers a session hello `service.unknown`; one with no session gate `service.off`). */
const UPDATE_REASONS = new Set(["service.unknown", "service.off"]);

/** Runs `run` once after `ms`; the answer cancels it. A test hands its own to run the asks itself. */
export type DialSchedule = (run: () => void, ms: number) => () => void;

const afterDelay: DialSchedule = (run, ms) => {
  const timer = setTimeout(run, ms);
  return () => clearTimeout(timer);
};

export class MachinesStore {
  private state: MachinesState = { removed: new Set(), dials: {} };
  /** Each waiting row's next ask. */
  private readonly rechecks = new Map<string, () => void>();
  /** Bumped by each ask the person starts on a row, so an older one's late answer is dropped. */
  private readonly dialRuns = new Map<string, number>();
  private readonly recheck: readonly number[];
  private readonly schedule: DialSchedule;
  private readonly listeners = new Set<() => void>();
  /** Bumped by every snapshot that lands, so a read that started before it is dropped. */
  private version = 0;
  private stopChanges?: () => void;
  private stopped = false;

  constructor(
    private readonly client: PageClient | null,
    options: { recheck?: readonly number[]; schedule?: DialSchedule } = {},
  ) {
    this.recheck = options.recheck ?? DIAL_RECHECK_MS;
    this.schedule = options.schedule ?? afterDelay;
  }

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.state;

  /** Follows the host's snapshots, then reads the current one. */
  async start(): Promise<void> {
    if (!this.client) return this.set({ ...this.state, unavailable: true });
    try {
      const stop = await this.client.subscribe<MachinesSnapshot>(MachinesOps.changes, (snapshot) =>
        this.land(snapshot),
      );
      if (this.stopped) stop();
      else this.stopChanges = stop;
    } catch {
      // Without the stream the section still shows what the read below returns.
    }
    await this.refresh();
  }

  stop(): void {
    this.stopped = true;
    this.stopChanges?.();
    this.stopChanges = undefined;
    for (const cancel of this.rechecks.values()) cancel();
    this.rechecks.clear();
  }

  async refresh(): Promise<void> {
    if (!this.client) return;
    const started = this.version;
    try {
      const snapshot = await this.client.call<MachinesSnapshot>(MachinesOps.snapshot, {});
      if (started === this.version) this.land(snapshot);
    } catch {
      // A failed read keeps what the section shows.
    }
  }

  /** Shows `snapshot` (the host's newest). A removed row it no longer lists as joined is done: gone,
   * or (a joined machine this app also runs) back as a plain machine row with the same id. */
  land(sample: MachinesSnapshot): void {
    this.version += 1;
    // The host sends every row on each change: an unchanged row keeps its object, so
    // the memoized rows draw only the machine that changed.
    const snapshot = keptSnapshot(this.state.snapshot, sample);
    const joined = new Set(snapshot.rows.filter((row) => row.joined).map((row) => row.id));
    const removed = new Set([...this.state.removed].filter((id) => joined.has(id)));
    this.set({ ...this.state, snapshot, removed });
  }

  /** Asks before Remove (the page's own dialog). */
  askRemove(row: string): void {
    this.set({ ...this.state, confirmRemove: row });
  }

  cancelRemove(): void {
    this.set({ ...this.state, confirmRemove: undefined });
  }

  /** Remove, confirmed: the row leaves now; the host revokes it and takes it off every list. A refusal
   * brings it back. */
  async remove(row: string): Promise<void> {
    const removed = new Set(this.state.removed).add(row);
    this.set({ ...this.state, confirmRemove: undefined, removed });
    let ok = false;
    try {
      ok = (await this.client?.call<{ removed?: boolean }>(MachinesOps.remove, { row }))?.removed === true;
    } catch {
      ok = false;
    }
    if (ok) return;
    const back = new Set(this.state.removed);
    back.delete(row);
    this.set({ ...this.state, removed: back });
  }

  newWorkspace(machine: string): void {
    void this.client?.call(MachinesOps.newWorkspace, { machine }).catch(() => undefined);
  }

  /** New Workspace (or Retry) on a joined Mac reached only through the hub: asks the host, which asks
   * that Mac. While it has not answered, the row says it is waiting and asks again on the
   * `recheck` steps; it opens the workspace once that Mac allows. Not now, an unreachable Mac or the
   * end of the wait stop it until the person clicks again. A click while an ask runs does nothing. */
  openJoined(row: string): void {
    const phase = this.state.dials[row];
    if (phase === "connecting" || phase === "waiting") return;
    const run = (this.dialRuns.get(row) ?? 0) + 1;
    this.dialRuns.set(row, run);
    this.setDial(row, "connecting");
    void this.ask(row, run, 0);
  }

  private async ask(row: string, run: number, attempt: number): Promise<void> {
    let answer: JoinedDialAnswer;
    try {
      answer = (await this.client?.call<JoinedDialAnswer>(
        MachinesOps.openJoined,
        attempt === 0 ? { row } : { row, again: true },
      )) ?? { state: "unavailable" };
    } catch {
      answer = { state: "unavailable" };
    }
    if (this.stopped || this.dialRuns.get(row) !== run) return;
    switch (answer.state) {
      case "opened":
        return this.setDial(row, undefined);
      case "consent_required": {
        const delay = this.recheck[attempt];
        if (delay === undefined) return this.setDial(row, "unanswered");
        this.setDial(row, "waiting");
        this.rechecks.set(
          row,
          this.schedule(() => {
            this.rechecks.delete(row);
            void this.ask(row, run, attempt + 1);
          }, delay),
        );
        return;
      }
      case "consent_declined":
        return this.setDial(row, "declined");
      default:
        return this.setDial(row, UPDATE_REASONS.has(answer.reason ?? "") ? "update" : "failed");
    }
  }

  private setDial(row: string, phase: JoinedDialPhase | undefined) {
    const dials = { ...this.state.dials };
    if (phase) dials[row] = phase;
    else delete dials[row];
    this.set({ ...this.state, dials });
  }

  addMachine(): void {
    void this.client?.call(MachinesOps.addMachine, {}).catch(() => undefined);
  }

  /** Opens a row's native menu at the page point (x, y); the row stays revealed until it closes. */
  async openMenu(row: string, menu: "row" | "joined", x: number, y: number): Promise<void> {
    if (!this.client) return;
    this.set({ ...this.state, menuOpen: row });
    try {
      await this.client.call(MachinesOps.menu, { row, menu, x, y });
    } catch {
      // No menu (no window, or the page closed): nothing to undo.
    } finally {
      if (this.state.menuOpen === row) this.set({ ...this.state, menuOpen: undefined });
    }
  }

  private set(state: MachinesState) {
    this.state = state;
    for (const listener of this.listeners) listener();
  }
}
