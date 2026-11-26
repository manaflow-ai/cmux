// What a row's text cannot show, on the one hover card (Chief, 2026-11-21, after a1315's tooltip cuts):
// a tooltip only names a control that shows no text, so a folder's whole path, a link's address, a
// command, a commit or an agent's whole name, which a `title` showed before, shows here instead. It is
// a hover card, not a tooltip: the card glass (ui/Tooltip.tsx AnchoredCard), the card dwell and grace
// (useHoverCard), and it opens at once on keyboard focus. Its facts are also the trigger's accessible
// description, always, through a hidden element (`aria-describedby`), so VoiceOver reads them on any
// role (an `aria-description` is not allowed on a button, link or list item: jsx-a11y).
import { useId, useState, type FocusEvent, type PointerEvent, type ReactNode } from "react";
import { AnchoredCard } from "../../../ui/Tooltip";
import { useHoverCard } from "./useHoverCard";
import "./factsCard.css";

/** One line of a facts card: a value, and what it is when the value alone does not say. */
export interface HoverFact {
  /** What the value is ("Schedule"), already localized; none when the value says it (a path, a URL). */
  label?: string;
  value: string;
  /** Monospace: a path, a command, a commit, an address. */
  code?: boolean;
}

/** What the trigger spreads: the hover and focus handlers, its anchor ref and its description. */
export interface FactsTrigger {
  ref: (element: HTMLElement | null) => void;
  "aria-describedby"?: string;
  onPointerEnter?: (event: PointerEvent<HTMLElement>) => void;
  onPointerMove?: (event: PointerEvent<HTMLElement>) => void;
  onPointerLeave?: (event: PointerEvent<HTMLElement>) => void;
  onFocus?: (event: FocusEvent<HTMLElement>) => void;
  onBlur?: () => void;
}

/** The facts that say something: a fact with no value is left out. */
function shown(facts: readonly (HoverFact | false | null | undefined)[]): HoverFact[] {
  return facts.filter(
    (fact): fact is HoverFact => !!fact && typeof fact.value === "string" && fact.value.trim() !== "",
  );
}

/** Its facts as one sentence for screen readers. */
function spoken(facts: readonly HoverFact[]): string {
  return facts.map((fact) => (fact.label ? `${fact.label}: ${fact.value}` : fact.value)).join(", ");
}

/**
 * Renders `children(trigger)` with a hover card of `facts`. Rows in a `.map` use it as is (it is a
 * component, not a hook). With no facts it renders the trigger alone, with no handlers.
 *
 * ```tsx
 * <WithFacts facts={[{ value: session.cwd, code: true }]}>
 *   {(trigger) => <span className="acpmux-home-project" {...trigger}>{project}</span>}
 * </WithFacts>
 * ```
 */
export function WithFacts({
  facts,
  side = "bottom",
  children,
}: {
  facts: readonly (HoverFact | false | null | undefined)[];
  side?: "top" | "bottom";
  children: (trigger: FactsTrigger) => ReactNode;
}) {
  const lines = shown(facts);
  const hover = useHoverCard();
  const [anchor, setAnchor] = useState<HTMLElement | null>(null);
  const id = useId();
  if (lines.length === 0) return <>{children({ ref: setAnchor })}</>;
  return (
    <>
      {children({ ref: setAnchor, "aria-describedby": id, ...hover.trigger })}
      <span id={id} hidden>
        {spoken(lines)}
      </span>
      <AnchoredCard
        anchor={hover.open ? anchor : null}
        className="ui-facts-card"
        side={side}
        instant
        hoverBridgeId={hover.card["data-cmux-hover-bridge"]}
        onPointerEnter={hover.card.onPointerEnter}
        onPointerLeave={hover.card.onPointerLeave}
      >
        <div className="ui-facts-card__body" data-facts-card="" {...hover.card}>
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
    </>
  );
}

/**
 * A text for screen readers only (a control's help sentence): spread `props` on the control and put
 * `node` beside it. A hidden element is still read as a description (`aria-describedby`), on every
 * role, where `aria-description` is not allowed.
 */
export function useDescription(text: string | false | null | undefined): {
  props: { "aria-describedby"?: string };
  node: ReactNode;
} {
  const id = useId();
  if (!text) return { props: {}, node: null };
  return {
    props: { "aria-describedby": id },
    node: (
      <span id={id} hidden>
        {text}
      </span>
    ),
  };
}

/** ``useDescription`` as a component, for a control inside a `.map`. */
export function Described({
  text,
  children,
}: {
  text: string | false | null | undefined;
  children: (props: { "aria-describedby"?: string }) => ReactNode;
}) {
  const description = useDescription(text);
  return (
    <>
      {children(description.props)}
      {description.node}
    </>
  );
}
