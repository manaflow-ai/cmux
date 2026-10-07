// Several renders from one turn (renderCall.ts): options side by side, up to three a line, the one
// the agent recommends marked on its card. Expand shows one option alone and opened, and Show all
// goes back to the options.
import { useState } from "react";
import { useT } from "../i18n";
import { RenderCard } from "./RenderCard";
import type { RenderCall } from "./renderCall";

export function RenderGroup({ calls }: { calls: readonly RenderCall[] }) {
  const t = useT();
  const [focused, setFocused] = useState<number | null>(null);
  const shown = focused === null ? undefined : calls[focused];
  if (shown)
    return (
      <div className="acpmux-render-group is-focused">
        <button type="button" className="acpmux-review-changes acpmux-render-group-back" onClick={() => setFocused(null)}>
          {t("render.showAll")}
        </button>
        <RenderCard call={shown} startExpanded />
      </div>
    );
  return (
    <div className="acpmux-render-group" style={{ gridTemplateColumns: `repeat(${Math.min(calls.length, 3)}, minmax(0, 1fr))` }}>
      {calls.map((call, index) => (
        <RenderCard key={index} call={call} compact onExpand={() => setFocused(index)} />
      ))}
    </div>
  );
}
