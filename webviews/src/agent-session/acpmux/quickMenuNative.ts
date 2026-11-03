import type { NativePopupEvent, NativePopupRow } from "../../ui/nativePopup";
import type { HarnessPlacement } from "../../ui/harnessPlacement";

/// The compact model menu's rows for the native popup host (WebPopupHost): the page describes them
/// and keeps every choice; AppKit draws them. Ids are short and stable while the menu is open, and
/// unique across the whole tree, as the native host requires.
export class QuickNativeRows {
  private ids = new Map<string, string>();
  readonly handlers = new Map<string, (event: NativePopupEvent) => void>();

  /** A fresh set of handlers for this render; ids stay stable across renders. */
  begin() {
    this.handlers.clear();
  }

  id(key: string): string {
    let id = this.ids.get(key);
    if (!id) {
      id = `q${this.ids.size}`;
      this.ids.set(key, id);
    }
    return id;
  }

  action(
    key: string,
    label: string,
    run: ((event: NativePopupEvent) => void) | undefined,
    extra: Partial<NativePopupRow> = {},
  ): NativePopupRow {
    const id = this.id(key);
    if (run && !extra.disabled) this.handlers.set(id, run);
    return { id, kind: "action", label, ...extra };
  }

  text(key: string, label: string): NativePopupRow {
    return { id: this.id(key), kind: "text", label };
  }

  section(key: string, label: string): NativePopupRow {
    return { id: this.id(key), kind: "section", label };
  }

  separator(key: string): NativePopupRow {
    return { id: this.id(key), kind: "separator", label: "" };
  }

  /** Runs the handler a native event names; false when none does. */
  dispatch(event: NativePopupEvent): boolean {
    const run = event.id === undefined ? undefined : this.handlers.get(event.id);
    run?.(event);
    return run !== undefined;
  }
}

/// No two separators in a row, and none first or last.
export function tidySeparators(rows: NativePopupRow[]): NativePopupRow[] {
  const out: NativePopupRow[] = [];
  for (const row of rows) {
    if (row.kind === "separator" && (out.length === 0 || out[out.length - 1]!.kind === "separator")) continue;
    out.push(row);
  }
  while (out.length && out[out.length - 1]!.kind === "separator") out.pop();
  return out;
}

/// The rail's column for the left and compact placements, as modelPicker.css sizes it: the named
/// left rail takes 36% of the menu (28% beside an effort column), the compact one 68 pt (76).
export function railColumn(placement: HarnessPlacement, width: number, effortColumn: boolean): number | undefined {
  if (placement === "left") return Math.round(width * (effortColumn ? 0.28 : 0.36));
  if (placement === "compact") return effortColumn ? 76 : 68;
  return undefined;
}

/// The menu's width: as wide as the rows a tab shows (`fit`), Claude Code style, plus the rail's
/// column beside the list. A row is its check, name, effort column, star and key.
export function quickMenuWidth(
  names: readonly string[],
  placement: HarnessPlacement,
  options: { effortColumn: boolean; stars: boolean; railed: boolean },
): number {
  const longest = names.reduce((most, name) => Math.max(most, name.length), 0);
  const list = 7 + 15 + Math.ceil(longest * 7.2) + (options.effortColumn ? 88 : 0) + (options.stars ? 22 : 0) + 40;
  const body = Math.min(480, Math.max(240, list));
  if (!options.railed) return body;
  if (placement === "left") return Math.min(1200, Math.round(body / (options.effortColumn ? 0.72 : 0.64)));
  if (placement === "compact") return Math.min(1200, body + (options.effortColumn ? 76 : 68) + 1);
  return body;
}
