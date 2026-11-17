// A Chief's turn controls on the Messages page, ported from the native compose button
// (MessagesLab ChatController+Stop.swift, CmuxNextHomeEngine HomeChiefTurnActions, CmuxNextApp
// HomeHostView+StopAll): while the Chief works the round button beside the field is Stop, and Escape
// or Cmd-. in the field stop it too; Option-click is Stop all agents, then a toast says what stopped
// and offers Restart for the subagents that did; after a stop the brain accepted, the same button is
// Continue until a new message or turn. The brain decides what each does (the host's
// `chief.*` ops, CmuxNextHome HomeMessagesChiefTurn); this keeps only when Continue shows.
import type { PageClient } from "../../shared/pageClient";
import type { Strings } from "../../shared/i18n";

export const CHIEF_TURN_OPS = {
  stop: "cmux.home.messages.chief.stop",
  stopAll: "cmux.home.messages.chief.stopAll",
  continue: "cmux.home.messages.chief.continue",
  restart: "cmux.home.messages.chief.restart",
  startAgent: "cmux.home.messages.chief.startAgent",
} as const;

/** What Stop all agents did (the brain's `chief.stop {all}` answer). */
export interface StopAllAnswer {
  stopped: boolean;
  subagents: string[];
  errors: string[];
  note?: string;
}

/** A toast over the message box (CmuxToast): its row, the tooltip, Restart's agents when any stopped. */
export interface ChiefToast {
  id: number;
  message: string;
  detail?: string;
  restart?: string[];
}

/** How long a toast shows (CmuxToast.stopAll's duration). */
export const TOAST_MS = 6000;

const strings = (value: unknown): string[] =>
  Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];

export function parseStopAll(raw: unknown): StopAllAnswer {
  const fields = (raw ?? {}) as Record<string, unknown>;
  const note = typeof fields.note === "string" ? fields.note : undefined;
  return {
    stopped: fields.stopped === true,
    subagents: strings(fields.subagents),
    errors: strings(fields.errors),
    ...(note ? { note } : {}),
  };
}

/** The toast's one row (HomeStopAllStrings.message, #38690): what stopped, never "all" while some
 * refused, then how many could not be stopped. Which and why, and the brain's note about any still
 * starting, are only the tooltip's: as a third line it read as a contradiction (hq#6246). */
export function stopAllMessage(answer: StopAllAnswer, words: Strings): string {
  const parts: string[] = [];
  if (answer.subagents.length) {
    const list = new Intl.ListFormat(words.language, { type: "conjunction" }).format(answer.subagents);
    parts.push(words.format(answer.errors.length ? "home.stopAll.stoppedSome" : "home.stopAll.stopped", list));
  } else if (!answer.errors.length) {
    parts.push(words.t(answer.stopped ? "home.stopAll.chiefOnly" : "home.stopAll.none"));
  } else if (answer.stopped) {
    parts.push(words.t("home.stopAll.chiefStopped"));
  }
  if (answer.errors.length) parts.push(words.format("home.stopAll.couldNotStop", String(answer.errors.length)));
  return parts.join(" · ");
}

/** The toast's tooltip (HomeStopAllStrings.detail): each refusal as the brain wrote it, then the note,
 * which only the tooltip carries. */
export function stopAllDetail(answer: StopAllAnswer): string | undefined {
  const lines = [...answer.errors, answer.note ?? ""].map((line) => line.trim()).filter(Boolean);
  return lines.length ? lines.join("\n") : undefined;
}

const refusalText = (error: unknown): string =>
  error && typeof error === "object" && "message" in error && typeof error.message === "string" ? error.message : "";

export interface ChiefTurnView {
  working: boolean;
  /** Continue shows (after an accepted stop, before the next message or turn). */
  continueAvailable: boolean;
  toast?: ChiefToast;
}

/** One conversation's Chief controls (HomeChiefTurnActions): a new message or a new turn ends a
 * stop's Continue; a stop answered after either is ignored. An external store: the page reads it
 * with `useSyncExternalStore`. Its one timer (the toast's) ends with the toast or `dispose`. */
export class ChiefTurn {
  private view: ChiefTurnView = { working: false, continueAvailable: false };
  private readonly listeners = new Set<() => void>();
  private stopped = false;
  private inFlight = false;
  private generation = 0;
  private sequence = -1;
  private toastTimer: ReturnType<typeof setTimeout> | undefined;
  private nextToast = 0;

  constructor(
    private readonly host: PageClient | null,
    private readonly conversation: string,
    private readonly words: Strings,
  ) {}

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getSnapshot = (): ChiefTurnView => this.view;

  /** The conversation's newest seq and whether its Chief works now. */
  update(working: boolean, sequence: number): void {
    if (sequence !== this.sequence || (working && !this.view.working)) {
      this.generation += 1;
      this.stopped = false;
    }
    this.sequence = sequence;
    this.publish({ working });
  }

  /** Stop (a click, Escape, Cmd-.), or Stop all agents (Option-click). */
  stop(all = false): void {
    if (all) {
      void this.stopAll();
      return;
    }
    if (!this.host || this.inFlight) return;
    this.inFlight = true;
    this.publish();
    const generation = this.generation;
    void this.host.call<unknown>(CHIEF_TURN_OPS.stop, { conversation: this.conversation }).then(
      (answer) => {
        this.inFlight = false;
        if (generation === this.generation && (answer as { stopped?: unknown } | null)?.stopped === true)
          this.stopped = true;
        this.publish();
      },
      (error: unknown) => {
        this.inFlight = false;
        this.publish();
        const text = refusalText(error);
        if (text) this.showToast({ message: text });
      },
    );
  }

  private async stopAll(): Promise<void> {
    if (!this.host || this.inFlight) return;
    this.inFlight = true;
    this.publish();
    try {
      const answer = parseStopAll(
        await this.host.call<unknown>(CHIEF_TURN_OPS.stopAll, { conversation: this.conversation }),
      );
      if (answer.stopped) this.stopped = true;
      const detail = stopAllDetail(answer);
      this.showToast({
        message: stopAllMessage(answer, this.words),
        ...(detail ? { detail } : {}),
        ...(answer.subagents.length ? { restart: answer.subagents } : {}),
      });
    } catch (error) {
      const text = refusalText(error);
      if (text) this.showToast({ message: text });
    } finally {
      this.inFlight = false;
      this.publish();
    }
  }

  /** Continue: the stopped turn goes on; a busy brain keeps Continue for another try. */
  continueTurn(): void {
    if (!this.host || !this.view.continueAvailable) return;
    this.inFlight = true;
    this.publish();
    const generation = this.generation;
    void this.host.call<unknown>(CHIEF_TURN_OPS.continue, { conversation: this.conversation }).then(
      (answer) => {
        this.inFlight = false;
        const result = (answer ?? {}) as { continued?: unknown; reason?: unknown };
        if (generation === this.generation) this.stopped = result.continued !== true && result.reason === "busy";
        this.publish();
      },
      () => {
        this.inFlight = false;
        if (generation === this.generation) this.stopped = true;
        this.publish();
      },
    );
  }

  /** Restart on the stop-all toast: those subagents go on; the toast closes. */
  restart(names: readonly string[]): void {
    this.dismissToast();
    if (!this.host || !names.length) return;
    void this.host
      .call<unknown>(CHIEF_TURN_OPS.restart, { conversation: this.conversation, names })
      .catch((error: unknown) => {
        const text = refusalText(error);
        if (text) this.showToast({ message: text });
      });
  }

  /** Start now on a queued agent's pill or card (`chief.startAgent`): true when the Chief started it.
   * A refusal shows the Chief's words in the toast, as a refused stop does. */
  async startAgent(agent: string): Promise<boolean> {
    if (!this.host) return false;
    try {
      await this.host.call<unknown>(CHIEF_TURN_OPS.startAgent, { conversation: this.conversation, agent });
      return true;
    } catch (error) {
      const text = refusalText(error);
      if (text) this.showToast({ message: text });
      return false;
    }
  }

  dismissToast(): void {
    if (this.toastTimer) clearTimeout(this.toastTimer);
    this.toastTimer = undefined;
    if (this.view.toast) this.publish({ toast: undefined });
  }

  dispose(): void {
    if (this.toastTimer) clearTimeout(this.toastTimer);
    this.toastTimer = undefined;
    this.listeners.clear();
  }

  private showToast(toast: Omit<ChiefToast, "id">): void {
    if (this.toastTimer) clearTimeout(this.toastTimer);
    this.nextToast += 1;
    this.publish({ toast: { id: this.nextToast, ...toast } });
    this.toastTimer = setTimeout(() => {
      this.toastTimer = undefined;
      this.publish({ toast: undefined });
    }, TOAST_MS);
  }

  private publish(change: Partial<ChiefTurnView> = {}): void {
    const working = change.working ?? this.view.working;
    const toast = "toast" in change ? change.toast : this.view.toast;
    const continueAvailable = this.stopped && !working && !this.inFlight;
    const next: ChiefTurnView = { working, continueAvailable, ...(toast ? { toast } : {}) };
    if (
      next.working === this.view.working &&
      next.continueAvailable === this.view.continueAvailable &&
      next.toast === this.view.toast
    )
      return;
    this.view = next;
    for (const listener of this.listeners) listener();
  }
}
