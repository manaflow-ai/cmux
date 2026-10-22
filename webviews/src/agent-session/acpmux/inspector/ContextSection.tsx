// The Inspector's Context, open (Claude Code desktop's): "43% used" with the tokens used of the
// window on the right, a bar split by what fills the window, then a row per part with its colored
// square, its tokens and its share of the window. acpmux reports only the window's totals today
// (`summary.usage`), so the parts are what is used and the free space.
import { useT } from "../i18n";
import "./ContextSection.css";

/// One part of the context window: its tokens and its share of the window (0 to 1).
export type ContextPart = { readonly id: "used" | "free"; readonly tokens: number; readonly share: number };

/// The window's parts, used first, whose shares add up to 1. Usage past the window counts as full.
export function contextParts(usage: { used: number; size: number }): ContextPart[] {
  const size = Math.max(0, usage.size);
  const used = Math.min(size, Math.max(0, usage.used));
  const share = (tokens: number) => (size > 0 ? tokens / size : 0);
  return [
    { id: "used", tokens: used, share: share(used) },
    { id: "free", tokens: size - used, share: share(size - used) },
  ];
}

export function ContextSection({ usage, percent }: { usage: { used: number; size: number }; percent: number }) {
  const t = useT();
  const tokens = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 });
  const share = new Intl.NumberFormat(undefined, { style: "percent", maximumFractionDigits: 1 });
  const parts = contextParts(usage);
  const label = (id: ContextPart["id"]) =>
    t(id === "used" ? "chatInspector.context.used" : "chatInspector.context.free");
  return (
    <div className="acpmux-chat-inspector-context" data-section="context">
      <div className="acpmux-chat-inspector-context__total">
        <span>{t("context.percent", { percent })}</span>
        <span className="acpmux-chat-inspector-context__tokens">
          {tokens.format(usage.used)} / {tokens.format(usage.size)}
        </span>
      </div>
      <div className="acpmux-chat-inspector-context__bar" aria-hidden="true">
        {parts
          .filter((part) => part.id !== "free" && part.share > 0)
          .map((part) => (
            <span key={part.id} data-part={part.id} style={{ width: `${part.share * 100}%` }} />
          ))}
      </div>
      <ul className="acpmux-chat-inspector-list">
        {parts.map((part) => (
          <li key={part.id} className="acpmux-chat-inspector-row" data-part={part.id}>
            <span className="acpmux-chat-inspector-context__swatch" data-part={part.id} aria-hidden="true" />
            <span className="acpmux-chat-inspector-row__name">{label(part.id)}</span>
            <span className="acpmux-chat-inspector-row__end acpmux-chat-inspector-context__count">
              {tokens.format(part.tokens)}
            </span>
            <span className="acpmux-chat-inspector-context__share">{share.format(part.share)}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
