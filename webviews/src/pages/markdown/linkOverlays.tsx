// The link overlays of the editor, as React over the ui wrapper: the hover card (ui AnchoredCard)
// and the link popover (ui Popover with a ui Combobox). linkEditing.tsx decides when they show and
// what they do (LinkOverlays state); these only render, inside the page's React tree.
import { useRef, useState, useSyncExternalStore } from "react";
import { Combobox } from "../../ui/Combobox";
import { Popover, type UiAnchor } from "../../ui/Popover";
import { AnchoredCard } from "../../ui/Tooltip";
import type { LinkCardInfo, LinkOverlays } from "./overlays";

/** Renders the editor's hover card and link popover (mount once in the page, under UiProvider). */
export function LinkOverlayHost({ overlays }: { overlays: LinkOverlays }) {
  const { card, popover } = useSyncExternalStore(overlays.subscribe, overlays.getState);
  return (
    <>
      <LinkCardView anchor={card?.anchor ?? null} info={card?.info ?? null} />
      {popover ? <LinkPopoverView key={popover.id} {...popover} /> : null}
    </>
  );
}

export function LinkCardView({ anchor, info }: { anchor: Element | null; info: LinkCardInfo | null }) {
  return (
    <AnchoredCard anchor={info ? anchor : null} className="md-link-card" state={info?.state}>
      <div className="md-link-card-target">{info?.target}</div>
      <div className="md-link-card-detail">{info?.detail}</div>
    </AnchoredCard>
  );
}

export interface LinkPopoverViewProps {
  anchor: UiAnchor;
  initial: string;
  label: string;
  placeholder: string;
  /** Suggestions for the typed text (headings for `#...`, workspace paths otherwise). */
  suggest(value: string): Promise<string[]>;
  onApply(href: string): void;
  onCancel(): void;
}

const MAX_SUGGESTIONS = 12;

export function LinkPopoverView({
  anchor,
  initial,
  label,
  placeholder,
  suggest,
  onApply,
  onCancel,
}: LinkPopoverViewProps) {
  const [items, setItems] = useState<string[]>([]);
  const ticket = useRef(0);
  const input = useRef<HTMLInputElement | null>(null);
  const started = useRef(false);
  const query = (value: string) => {
    const id = ++ticket.current;
    void suggest(value).then(
      (next) => {
        if (id === ticket.current) setItems(next.slice(0, MAX_SUGGESTIONS));
      },
      () => {
        if (id === ticket.current) setItems([]);
      },
    );
  };
  // A callback ref: the field takes focus with its text selected, and the first suggestions load.
  const inputRef = (element: HTMLInputElement | null) => {
    input.current = element;
    if (!element || started.current) return;
    started.current = true;
    element.focus({ preventScroll: true });
    element.select();
    query(initial);
  };
  return (
    <Popover
      open
      onOpenChange={(open) => !open && onCancel()}
      anchor={anchor}
      label={label}
      className="md-link-popover"
      initialFocus={input}
      finalFocus={false}
    >
      <Combobox
        inline
        inputRef={inputRef}
        defaultValue={initial}
        suggestions={items}
        onQuery={query}
        onSubmit={(value) => onApply(value.trim())}
        onCancel={onCancel}
        label={placeholder}
        placeholder={placeholder}
        inputClassName="md-link-input"
        listClassName="md-link-suggestions"
      />
    </Popover>
  );
}
