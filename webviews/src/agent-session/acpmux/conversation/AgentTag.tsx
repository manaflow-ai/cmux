import type { HTMLAttributes, MouseEvent, PointerEvent, ReactNode, Ref } from "react";
import type { SessionHoverTrigger } from "../started/useSessionHover";
import { WithFacts } from "../chips/FactsHoverCard";
import "./AgentTag.css";

/** A compact agent or lane name tag shared by transcript activity rows. One that opens a chat is a
 *  link chip: the theme's text on a wash of it and real padding, lit on its own on hover, never
 *  with its row, and no arrow glyph (Leo, 2026-11-01: "nobody asked for that up right arrow") (Leo, 2026-11-01: "this highlight is both not aligned with the icon vertically and
 *  too small and also not prominent enough because the whole line gets highlighted and it's not
 *  obvious that clicking on this will be a new thing"). It can be a hover card's trigger
 *  (ui/Tooltip.tsx renders it with the card's props and ref: a subagent's preview,
 *  subagents/SubagentPreview.tsx); those props go under the tag's own. */
export function AgentTag({
  name,
  title,
  about,
  onClick,
  ariaLabel,
  className,
  attributes,
  hover,
  ref,
  ...trigger
}: {
  name: ReactNode;
  title?: string;
  /// What a tag that opens a chat cannot show (its harness, model and effort): on its facts card when
  /// no chat hover card says more. A plain tag's `title` does this.
  about?: string;
  onClick?(event: MouseEvent<HTMLButtonElement>): void;
  ariaLabel?: string;
  className?: string;
  /// More attributes on the button (`openSessionAttributes`).
  attributes?: Record<string, string | undefined>;
  /// The hover card of the chat it opens (``useSessionHover``).
  hover?: SessionHoverTrigger;
  /// A hover card trigger's ref (ui/Tooltip.tsx).
  ref?: Ref<HTMLElement>;
} & Omit<HTMLAttributes<HTMLElement>, "onClick" | "title" | "className">) {
  const classes = `cv-agent-tag${className ? ` ${className}` : ""}`;
  if (onClick) {
    // A chat's hover card (or a hover card trigger's) says more and would sit under the facts card.
    const said = hover?.onPointerEnter || trigger.onPointerEnter ? [] : [{ value: about ?? "" }];
    return (
      <WithFacts facts={said}>
        {({ ref: anchor, ...card }) => (
          <button
            {...trigger}
            {...card}
            ref={(element: HTMLButtonElement | null) => {
              anchor(element);
              if (typeof ref === "function") ref(element);
              else if (ref) (ref as { current: HTMLElement | null }).current = element;
            }}
            type="button"
            className={`${classes} is-open`}
            aria-label={ariaLabel}
            data-interactive=""
            {...attributes}
            {...hover}
            // The chip lights under the pointer only once the pointer has moved on it: one that
            // appears under a resting pointer (a start line drawn where the pointer sits) is not
            // pointed at, and lit it read as a stray outline (Leo, 2026-11-24: "this is pretty
            // weird? it was collasped then expanded? idk"). Keyboard focus lights it as before.
            onPointerMove={(event: PointerEvent<HTMLButtonElement>) => {
              (hover?.onPointerMove ?? card.onPointerMove ?? trigger.onPointerMove)?.(event);
              if (!event.currentTarget.hasAttribute("data-pointed"))
                event.currentTarget.setAttribute("data-pointed", "");
            }}
            onPointerLeave={(event: PointerEvent<HTMLButtonElement>) => {
              const leave = (hover?.onPointerLeave ?? card.onPointerLeave ?? trigger.onPointerLeave) as
                | ((event: PointerEvent<HTMLButtonElement>) => void)
                | undefined;
              leave?.(event);
              event.currentTarget.removeAttribute("data-pointed");
            }}
            onClick={(event) => {
              // A hover card trigger's own click (it puts the card away) runs first.
              (trigger as { onClick?(event: MouseEvent<HTMLButtonElement>): void }).onClick?.(event);
              onClick(event);
            }}
          >
            <span className="cv-agent-tag__label">{name}</span>
          </button>
        )}
      </WithFacts>
    );
  }
  // A plain tag's title (the agent's whole name) shows on its facts card; a hover card the tag
  // triggers (ui/Tooltip.tsx passes its handlers in `trigger`) says more and would sit under it.
  const facts = trigger.onPointerEnter ? [] : [{ value: title ?? "" }];
  /** The tag's own ref and the facts card's anchor, on one element. */
  const both =
    (anchor: (element: HTMLElement | null) => void) =>
    (element: HTMLElement | null): void => {
      anchor(element);
      if (typeof ref === "function") ref(element);
      else if (ref) (ref as { current: HTMLElement | null }).current = element;
    };
  return (
    <WithFacts facts={facts}>
      {({ ref: anchor, ...card }) => (
        <span
          {...trigger}
          {...card}
          ref={both(anchor)}
          className={`${classes} is-plain`}
          data-interactive=""
          aria-hidden="true"
        >
          {name}
        </span>
      )}
    </WithFacts>
  );
}
