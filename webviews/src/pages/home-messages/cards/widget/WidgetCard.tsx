// A message's chat widget as a card in the received bubble's colours (plans/cmux-next/chat-widgets-
// DESIGN.md section 4), ported from the deleted native row, MessagesLabHome `HomeWidgetRowProvider`
// (`drawRow`: text, rows with a symbol and a badge, buttons, badges, dividers, empty states) with its
// fonts and tints (`HomeWidgetStyle.swift`) as the page's tokens and its SF symbols as the page's
// icons (`HomeWidgetSymbols.swift`, here apps/scene `SceneSymbol`). While the host has no snapshot
// (loading, no app installed, a failed mount, no host at all) the bubble is the part's fallback text.
// A click on a row or an enabled button goes to its scene node; nothing else takes one.
import { useContext, useEffect, useState } from "react";
import type { HomeWidgetPart } from "../../../home-channels/types";
import { SceneSymbol } from "../../../../apps/scene/SceneSymbol";
import { widgetKey, widgetWire, WIDGET_LAYOUT, type WidgetItem, type WidgetSnapshot } from "./widgetModel";
import { WidgetContext } from "./widgetService";
import "./widget.css";

/** The widget's current snapshot from the host: undefined until it answers, and while it has none.
 * A change from the host wins over an answer still on its way (the answer is older). */
export function useWidgetSnapshot(key: string, part: HomeWidgetPart): WidgetSnapshot | undefined {
  const service = useContext(WidgetContext);
  const [state, setState] = useState<{ key: string; wire: string; snapshot?: WidgetSnapshot }>();
  // The part by value: a new render of the same part asks nothing; an edited one asks again.
  const wire = JSON.stringify(widgetWire(part));
  useEffect(() => {
    if (!service) return;
    let live = true;
    let changed = false;
    const set = (snapshot: WidgetSnapshot | undefined) => setState(snapshot ? { key, wire, snapshot } : { key, wire });
    const stop = service.subscribe((changedKey, snapshot) => {
      if (!live || changedKey !== key) return;
      changed = true;
      set(snapshot);
    });
    void service
      .snapshot(key, { type: "widget", ...(JSON.parse(wire) as Omit<HomeWidgetPart, "type">) })
      .then((snapshot) => {
        if (live && !changed) set(snapshot);
      });
    return () => {
      live = false;
      stop();
    };
  }, [service, key, wire]);
  return state?.key === key && state.wire === wire ? state.snapshot : undefined;
}

/** A `widget` part: its card, or its fallback text. */
export function WidgetCard({ message, partIndex, part }: { message: string; partIndex: number; part: HomeWidgetPart }) {
  const key = widgetKey(message, partIndex);
  const snapshot = useWidgetSnapshot(key, part);
  const service = useContext(WidgetContext);
  if (!snapshot)
    return (
      <div className="hm-part-card hm-widget hm-widget--fallback" data-widget={key}>
        <span className="mt-text">{part.fallback}</span>
      </div>
    );
  return <WidgetBody widget={key} snapshot={snapshot} onTap={(node) => service?.tap(key, node)} />;
}

/** The card itself, from a snapshot (the gallery draws fixed ones). */
export function WidgetBody({
  widget,
  snapshot,
  onTap,
}: {
  widget: string;
  snapshot: WidgetSnapshot;
  onTap?(node: string): void;
}) {
  return (
    <div className="hm-part-card hm-widget" data-widget={widget}>
      {snapshot.items.slice(0, WIDGET_LAYOUT.maxItems).map((item, index) => (
        <WidgetItemView key={index} item={item} onTap={onTap} />
      ))}
    </div>
  );
}

function WidgetItemView({ item, onTap }: { item: WidgetItem; onTap: ((node: string) => void) | undefined }) {
  switch (item.type) {
    case "text":
      return (
        <p className="hm-widget__text" data-style={item.style} data-tint={item.tint}>
          {item.text}
        </p>
      );
    case "row": {
      const body = (
        <>
          {item.symbol && (
            <span className="hm-widget__symbol" data-tint={item.tint}>
              <SceneSymbol symbol={item.symbol} size={16} />
            </span>
          )}
          <span className="hm-widget__titles">
            <span className="hm-widget__title">{item.title}</span>
            {item.subtitle && <span className="hm-widget__subtitle">{item.subtitle}</span>}
          </span>
          {item.badge && (
            <span className="hm-widget__badge" data-tint={item.tint}>
              {item.badge}
            </span>
          )}
        </>
      );
      const node = item.node;
      return node ? (
        <button type="button" className="hm-widget__row" data-node={node} onClick={() => onTap?.(node)}>
          {body}
        </button>
      ) : (
        <div className="hm-widget__row">{body}</div>
      );
    }
    case "buttons":
      return (
        <div className="hm-widget__buttons" style={{ gridTemplateColumns: `repeat(${item.buttons.length}, 1fr)` }}>
          {item.buttons.map((button) => (
            <button
              key={button.node}
              type="button"
              className="hm-widget__button"
              data-node={button.node}
              data-prominent={button.prominent ? "" : undefined}
              disabled={!button.enabled}
              onClick={() => onTap?.(button.node)}
            >
              {button.title}
            </button>
          ))}
        </div>
      );
    case "badge":
      return (
        <span className="hm-widget__badge hm-widget__pill" data-tint={item.tint}>
          {item.text}
        </span>
      );
    case "divider":
      return <hr className="hm-widget__divider" />;
    case "empty":
      return (
        <div className="hm-widget__empty">
          {item.symbol && <SceneSymbol symbol={item.symbol} size={20} className="hm-widget__empty-symbol" />}
          <span className="hm-widget__title">{item.title}</span>
          {item.message && <span className="hm-widget__subtitle">{item.message}</span>}
        </div>
      );
  }
}
