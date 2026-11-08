// Lists a search field drives: the field keeps the keyboard and names the row the arrows reach
// (aria-activedescendant on the field), so a press on a row picks it without taking focus from the
// field. The caller owns the highlight, the keys and the scrolling.
//
// Base UI 1.8 has no list with a caller-owned highlight driven from an outside field (DrillList is
// that for one folder level, with its own field), so these parts are implemented here, once. The
// model menu's columns (QuickModelColumns.tsx: the harness rail, the models, a model's settings and
// the account card) are built from them.
import type { HTMLAttributes, KeyboardEvent, Ref } from "react";

type DivProps = Omit<HTMLAttributes<HTMLDivElement>, "role"> & {
  [data: `data-${string}`]: string | undefined;
  ref?: Ref<HTMLDivElement>;
};

/** A list a field outside it drives: `listbox` for picks, `tablist` for a rail of tabs. */
export function DrivenList({ kind, label, ...rest }: DivProps & { kind: "listbox" | "tablist"; label: string }) {
  return <div {...rest} role={kind} aria-label={label} />;
}

/** What a row of a driven list is. */
export type DrivenRowKind = "option" | "tab" | "radio" | "switch" | "button";

/**
 * A row of a driven list. A press never takes focus (the field keeps it); a click or Return or
 * Space on the row itself picks it. `tabbable` rows take Tab (a card's rows, an action at a list's
 * end); the others stay out of the tab order, reached through the field.
 */
export function DrivenRow({
  kind,
  onPick,
  tabbable,
  ...rest
}: Omit<DivProps, "onClick"> & { kind: DrivenRowKind; onPick(): void; tabbable?: boolean }) {
  return (
    // oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- `kind` is the row's role (option, tab, radio, switch, button)
    <div
      {...rest}
      role={kind}
      tabIndex={tabbable ? 0 : -1}
      onPointerDown={(event) => event.preventDefault()}
      onClick={onPick}
      onKeyDown={(event: KeyboardEvent<HTMLDivElement>) => {
        if (event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault();
        event.stopPropagation();
        onPick();
      }}
    />
  );
}

/**
 * A card that opens inside a popup, over its lists (an account card under an avatar): a non-modal
 * dialog the popup's own Escape and outside press close.
 */
export function InlineCard({ label, ...rest }: DivProps & { label: string }) {
  // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a card inside the popover, not a modal <dialog>
  return <div {...rest} role="dialog" aria-label={label} />;
}
