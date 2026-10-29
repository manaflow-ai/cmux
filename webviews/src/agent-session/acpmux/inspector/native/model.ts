// Session Info drawn natively (Leo, 2026-10-29: "plus we're gonna be doing that part natively in swift
// anyways?"): the page still reads the chat (acpmux's summary, the transcript, the process registry) and
// works out what each section lists, but the App draws the panel (AgentPaneSessionInfo.swift) over the
// pane, the full height of the chat, with no layout of the page's own. This is what the page hands the
// App (`pane.sessionInfo`): plain text, SF Symbol names and action ids, nothing the App interprets. A
// click comes back as `sessionInfoAction {id}` and runs the action the page registered for that id.
import type { InspectorGroupId } from "../sectionOrder";
import type { InspectorSectionId } from "../inspectorState";

/// How a row or a section's value reads: running rows draw a spinner, failed ones the error ink.
export type NativeInfoTone = "running" | "waiting" | "failed" | "done" | "muted" | "accent";

/// A button at a row's trailing edge (Stop, Reconnect, Save, the limit's − and +).
export type NativeInfoButton = {
  /// Its accessible name and tooltip; shown as text when it has no symbol.
  label: string;
  symbol?: string;
  action: string;
  disabled?: boolean;
};

export type NativeInfoRow = {
  /// Stable within its section, so the App keeps the row's hover and focus across updates.
  id: string;
  /// An SF Symbol name.
  symbol?: string;
  title: string;
  /// Dimmer text after the title on the same line (a command's folder, a subagent's prompt).
  detail?: string;
  /// A second line under the title.
  subtitle?: string;
  /// Right-aligned text (a time, a count, a state).
  trailing?: string;
  tone?: NativeInfoTone;
  /// Nesting under the row above, 0 to 3.
  indent?: number;
  /// 0...1: a thin meter under the row (Context's share of the window).
  meter?: number;
  /// What a click on the row does.
  action?: string;
  buttons?: readonly NativeInfoButton[];
  /// The row's tooltip (a full path, a full prompt).
  help?: string;
};

export type NativeInfoSection = {
  id: InspectorSectionId;
  group: InspectorGroupId;
  title: string;
  /// The title's leading SF Symbol (Context, Connectors in the top block).
  symbol?: string;
  /// The value beside the title (a count, a percent, "2 running").
  meta?: string;
  metaTone?: NativeInfoTone;
  /// 0...1: the meter beside the title (Context).
  meter?: number;
  /// No title row: the rows alone (Environment heads the panel bare).
  bare?: boolean;
  /// Unfolded; a folded section shows its title row only.
  open: boolean;
  /// Its title row folds and unfolds it.
  foldable: boolean;
  rows: readonly NativeInfoRow[];
  /// A last row that lists more or fewer (Sources' View all N / Show fewer).
  more?: { label: string; action: string };
};

export type NativeSessionInfo = {
  /// The panel shows: the toggle is on and nothing took the pane (a diff in place).
  open: boolean;
  /// Its width in CSS pixels (the person's drag, INSPECTOR_WIDTH).
  width: number;
  /// Where it starts below the pane's top, in CSS pixels: under the header or the shared tab row,
  /// so it never covers the header's tools.
  top: number;
  /// How far from the pane's right edge it floats, in CSS pixels: a side panel's width beside the chat.
  side: number;
  /// Over the chat's column, how far above the pane's foot it stops (the composer's stack), CSS
  /// pixels; none runs it to the foot less the float margin.
  foot?: number;
  /// The panel's accessible name ("Session Info", in the page's language).
  label: string;
  /// A subagent's own panel names the subagent at its top (its breadcrumb).
  title?: string;
  /// In the person's order (sectionOrder.ts), blocks first: where it runs, what it made, what it runs.
  sections: readonly NativeInfoSection[];
};

/// Longest id the App hands back (host.ts refuses longer); a longer one is sent as a short hash of it.
export const NATIVE_ACTION_ID_MAX = 512;
const ID_KEEP = 200;

/// A long id (a signed URL, a deep path) as `<its first 200 characters>#<hash of all of it>`: as stable
/// across updates as the id itself, and short enough to come back.
function boundedId(id: string): string {
  if (id.length <= ID_KEEP) return id;
  let low = 0x811c9dc5;
  let high = 0x01000193;
  for (let index = 0; index < id.length; index++) {
    const code = id.charCodeAt(index);
    low = Math.imul(low ^ code, 0x01000193) >>> 0;
    high = Math.imul(high ^ code, 0x85ebca6b) >>> 0;
  }
  return `${id.slice(0, ID_KEEP)}#${low.toString(36)}${high.toString(36)}`;
}

/// The actions one model's rows and buttons name: `add` keeps `run` under `id` (unique in the model,
/// stable across updates, e.g. `tasks.stop:<processId>`) and returns the id the row sends, bounded so
/// the App can always hand it back.
export class NativeInfoActions {
  private readonly runs = new Map<string, () => unknown>();
  add(id: string, run: () => unknown): string {
    const key = boundedId(id);
    this.runs.set(key, run);
    return key;
  }
  /// Runs the action the App's click named; false when this model has none by that id (an update
  /// raced the click).
  run(id: string): boolean {
    const run = this.runs.get(id);
    if (!run) return false;
    void Promise.resolve()
      .then(run)
      .catch(() => undefined);
    return true;
  }
}
