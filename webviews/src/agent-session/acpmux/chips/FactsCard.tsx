// The facts hover card itself (FactsHoverCard.tsx's WithFacts draws it): the card glass and its
// positioner (ui/Tooltip.tsx AnchoredCard, Base UI's tooltip). A page draws a card only on hover or
// focus, so this file is its own chunk, fetched once the page is idle (`loadFactsCard`), and a
// page whose first screen shows triggers only (Home Messages, Home Channels) starts without it. Its
// stylesheet stays with WithFacts (factsCard.css), so a surface's CSS has it from the first frame.
import { AnchoredCard } from "../../../ui/Tooltip";
import type { HoverFact } from "./FactsHoverCard";
import type { useHoverCard } from "./useHoverCard";

/** The card of WithFacts' `lines` at `anchor` (none while it is closed); `card` is useHoverCard's. */
export function FactsCard({
  anchor,
  side,
  lines,
  card,
}: {
  anchor: HTMLElement | null;
  side: "top" | "bottom";
  lines: readonly HoverFact[];
  card: ReturnType<typeof useHoverCard>["card"];
}) {
  return (
    <AnchoredCard
      anchor={anchor}
      className="ui-facts-card"
      side={side}
      instant
      hoverBridgeId={card["data-cmux-hover-bridge"]}
      onPointerEnter={card.onPointerEnter}
      onPointerLeave={card.onPointerLeave}
    >
      <div className="ui-facts-card__body" data-facts-card="" {...card}>
        {lines.map((fact, index) => (
          <div key={index} className="ui-facts-card__fact">
            {fact.label && <span className="ui-facts-card__label">{fact.label}</span>}
            <span className="ui-facts-card__value" data-code={fact.code ? "" : undefined}>
              {fact.value}
            </span>
          </div>
        ))}
      </div>
    </AnchoredCard>
  );
}
