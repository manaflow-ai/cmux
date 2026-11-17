import { Fragment, useEffect, useMemo, useState, type ReactNode } from "react";
import { panelId } from "../../../apps/scene/panelsClient";
import { usePageNow } from "../../../ui/pageClock";
import { ExtensionWidgetCell, GRID_BUILTINS, gridOrder, type NewTabExtensionWidgets } from "./ExtensionWidgets";
import type { PageWidget, WidgetEdit } from "./pageWidgets";
import { useNt } from "./strings";
import { GridWidgetFrame, type WidgetEditing } from "./WidgetEditing";

const QUOTES = [
  ["quote.1", "Mark Twain"],
  ["quote.2", "Aristotle"],
  ["quote.3", "Ralph Waldo Emerson"],
  ["quote.4", "Vincent van Gogh"],
] as const;

/// Each built-in cell's name, for its ✕ in edit mode.
const BUILTIN_NAMES = {
  warmGreeting: "widget.warmGreeting",
  clock: "widget.clock",
  timer: "widget.timer",
  quote: "widget.quote",
} as const;

function dayIndex(now: number): number {
  return Math.floor(now / 86_400_000) % QUOTES.length;
}

/// The page's widget row: the built-in clock, timer, warm greeting and quote, and the widgets of
/// installed apps the person placed (ExtensionWidgets.tsx), in the person's order (the daemon's New Tab
/// layout). In edit mode each cell moves and closes as the page's other widgets do.
export function NewTabExtras({
  widgets,
  now,
  extensions,
  editing,
  onEdit,
}: {
  widgets: ReadonlySet<string>;
  now: number;
  /// The placed app widgets and the layout; none when omitted.
  extensions?: NewTabExtensionWidgets;
  editing?: WidgetEditing;
  /// The page's edit mode saves an edit to a built-in widget (Settings' switch); unset, no edit mode.
  onEdit?(edit: WidgetEdit): void;
}) {
  const nt = useNt();
  const timerOn = widgets.has("timer");
  const [started, setStarted] = useState<number>();
  useEffect(() => setStarted(timerOn ? Date.now() : undefined), [timerOn]);
  // The stopwatch reads wall time on the page's shared second clock, so a hidden page runs no timer
  // and catches up when shown.
  const tick = usePageNow(timerOn);
  const elapsed = started === undefined ? 0 : Math.max(0, Math.floor((tick - started) / 1000));
  const quote = useMemo(() => QUOTES[dayIndex(now)]!, [now]);
  const hour = new Date(now).getHours();
  const warm = nt(hour < 12 ? "extra.morning" : hour < 18 ? "extra.afternoon" : "extra.evening");
  const builtins = GRID_BUILTINS.filter((widget) => widgets.has(widget));
  const placed = extensions?.mounted ?? [];
  if (!builtins.length && !placed.length) return null;
  const cells = new Map<string, { node: ReactNode; label: string; wide: boolean; builtin?: PageWidget }>();
  for (const widget of builtins) {
    const node =
      widget === "warmGreeting" ? (
        <div className="nt-extra-warm">{warm}</div>
      ) : widget === "clock" ? (
        <time className="nt-extra-clock" dateTime={new Date(now).toISOString()}>
          {new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" }).format(now)}
        </time>
      ) : widget === "timer" ? (
        <div className="nt-extra-timer" role="timer">
          {nt("extra.stopwatch")} {Math.floor(elapsed / 60)}:{String(elapsed % 60).padStart(2, "0")}
        </div>
      ) : (
        <figure className="nt-extra-quote">
          <blockquote>“{nt(quote[0])}”</blockquote>
          <figcaption>— {quote[1]}</figcaption>
        </figure>
      );
    const wide = widget === "warmGreeting" || widget === "quote";
    cells.set(widget, { node, label: nt(BUILTIN_NAMES[widget]), wide, builtin: widget });
  }
  for (const widget of placed)
    cells.set(panelId(widget.panel), {
      node: <ExtensionWidgetCell widget={widget} />,
      label: widget.panel.title,
      wide: widget.panel.size === "wide",
    });
  const order = gridOrder([...cells.keys()], extensions?.layout ?? []);
  // Edit frames only where the host keeps the row's order: without it the row edits as it did
  // before app widgets (not at all; its built-ins switch in Settings and Add Widgets).
  const edit = editing?.editing && onEdit && extensions?.editable ? { editing, onEdit, extensions } : undefined;
  return (
    <div className="nt-extras" aria-label={nt("extra.widgets")} data-editing={edit ? "" : undefined}>
      {order.map((id) => {
        const cell = cells.get(id)!;
        // Out of edit mode a cell is its content alone, as the row drew before app widgets.
        if (!edit) return <Fragment key={id}>{cell.node}</Fragment>;
        const { builtin } = cell;
        return (
          <GridWidgetFrame
            key={id}
            id={id}
            label={cell.label}
            order={order}
            editing={edit.editing}
            {...(cell.wide ? { className: "nt-grid-cell-wide" } : {})}
            onRemove={() =>
              builtin
                ? edit.onEdit({ edit: "remove", widget: builtin })
                : edit.extensions.setLayout(edit.extensions.layout.filter((each) => each !== id))
            }
            onMove={(next) => edit.extensions.setLayout(next)}
          >
            {cell.node}
          </GridWidgetFrame>
        );
      })}
    </div>
  );
}
