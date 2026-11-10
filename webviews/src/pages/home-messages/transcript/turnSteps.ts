// The running Chief turn's steps as the page saw them, and the status line's text, ported from
// MessagesLab HomeTurnSteps, HomeTurnProgress (`steps` style) and HomeLiveLine. The owner sends only
// the newest "working on" line (`run.activity`), so this is the page's own record of the turn so far:
// one step per distinct line, each from its start to the next one's; a line that sharpens with the
// same start (a tool's input arrived) stays one step.
import { formatDuration } from "../../../agent-session/acpmux/conversation/turns";
import type { Strings } from "../../shared/i18n";

export interface TurnActivity {
  line: string;
  /** When this step began (epoch ms). */
  since: number;
}

export interface TurnStep {
  line: string;
  start: number;
  /** The next step's start; absent while this one runs. */
  end?: number;
}

/** At most this many steps are kept (the oldest go first); the turn's start stays. */
export const TURN_STEP_LIMIT = 200;

/** Lines the owner sends for its own writing, not a step of the turn's work (HomeLiveActivity.modelLines). */
const NOT_STEPS = new Set(["Thinking", "Writing the reply", "Working"]);

export class TurnSteps {
  private list: TurnStep[] = [];
  private started: number | undefined;

  get steps(): readonly TurnStep[] {
    return this.list;
  }

  /** The turn's start (its first step's). */
  get start(): number | undefined {
    return this.started;
  }

  record(activity: TurnActivity): void {
    const last = this.list.at(-1);
    if (last) {
      if (last.start === activity.since) {
        // The same work, a sharper line ("Telling an agent" -> "Telling a31").
        this.list[this.list.length - 1] = { ...last, line: activity.line };
        return;
      }
      if (activity.since < last.start) {
        // Older than the newest step: a new run's clock (or a resend of an old frame). Start over.
        this.list = [];
        this.started = undefined;
      } else {
        this.list[this.list.length - 1] = { ...last, end: activity.since };
      }
    }
    this.started ??= activity.since;
    this.list.push({ line: activity.line, start: activity.since });
    if (this.list.length > TURN_STEP_LIMIT) this.list.splice(0, this.list.length - TURN_STEP_LIMIT);
  }
}

/** "4s", "1m 5s", "2h 3m"; none under a second (HomeLiveLine.elapsed). */
export function elapsed(ms: number): string | undefined {
  return ms >= 1000 ? formatDuration(ms) : undefined;
}

/** The step running now and its time so far ("Checking on a31 · 2m 10s"). */
export function currentLine(activity: TurnActivity, now: number): string {
  const time = elapsed(now - activity.since);
  return time ? `${activity.line} · ${time}` : activity.line;
}

type Kind = "commands" | "reads" | "edits" | "searches" | "other";

/** What a finished step did, by the verb the owner's line starts with (optchat-chief's `activity_line`). */
export function stepKind(line: string): Kind {
  if (line.startsWith("Running ")) return "commands";
  // "Reading the chat history" and "Reading the Chief's profile" are the Chief's own tools, not files.
  if (line.startsWith("Reading ") && !line.startsWith("Reading the ")) return "reads";
  if (line.startsWith("Editing ") || line.startsWith("Deleting ") || line.startsWith("Moving ")) return "edits";
  if (line.startsWith("Searching")) return "searches";
  return "other";
}

const FOLD_KEYS: Record<Exclude<Kind, "other">, string> = {
  commands: "home.turn.ranCommands",
  reads: "home.turn.readFiles",
  edits: "home.turn.editedFiles",
  searches: "home.turn.ranSearches",
};

/** The finished steps in one row (HomeTurnProgress.summary): each kind with two or more steps by its
 * fold label ("Ran 3 commands"), in the order the turn first did it; a single other step by its own
 * line, several not at all; then "›", since a click lists every step. None before a step finished,
 * or when nothing is left to name. */
export function stepsSummary(finished: readonly string[], strings: Strings): string | undefined {
  const lines = finished.filter((line) => !NOT_STEPS.has(line));
  if (!lines.length) return undefined;
  const order: Kind[] = [];
  const counts = new Map<Kind, number>();
  for (const line of lines) {
    const kind = stepKind(line);
    if (!counts.has(kind)) order.push(kind);
    counts.set(kind, (counts.get(kind) ?? 0) + 1);
  }
  const parts: string[] = [];
  const rest: string[] = [];
  for (const kind of order) {
    const count = counts.get(kind) ?? 0;
    if (kind !== "other" && count >= 2) parts.push(strings.format(FOLD_KEYS[kind], String(count)));
    else rest.push(...lines.filter((line) => stepKind(line) === kind));
  }
  if (rest.length === 1) parts.push(rest[0]!);
  return parts.length ? `${parts.join(" · ")} ›` : undefined;
}

/** The status line's parts, side by side on one line: the folded finished steps, then the running one. */
export function statusParts(steps: TurnSteps, activity: TurnActivity, now: number, strings: Strings): string[] {
  const finished = steps.steps.filter((step) => step.end !== undefined).map((step) => step.line);
  const summary = stepsSummary(finished, strings);
  return [...(summary ? [summary] : []), currentLine(activity, now)];
}

export interface TurnDetailRow {
  line: string;
  duration: string;
  running: boolean;
}

/** What the status line's popover lists (HomeTurnDetails): each step with how long it took (the
 * running one: "now"), and the turn's total so far. */
export function turnDetails(steps: TurnSteps, now: number, strings: Strings): { rows: TurnDetailRow[]; total: string } {
  const rows = steps.steps.map((step) => {
    const running = step.end === undefined;
    const ms = (step.end ?? now) - step.start;
    return {
      line: step.line,
      duration: running ? strings.t("home.turn.now") : (elapsed(ms) ?? strings.t("home.turn.under1s")),
      running,
    };
  });
  const start = steps.start;
  const total = start === undefined ? 0 : now - start;
  return { rows, total: strings.format("home.turn.total", elapsed(total) ?? strings.t("home.turn.under1s")) };
}
