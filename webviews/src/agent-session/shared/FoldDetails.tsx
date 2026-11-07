// A native <details> whose body opens and closes as one motion: the body's height and opacity move
// together on the settle (--cmux-ease-settle over --cmux-motion-settle) through Session Info's fold
// (session-info/foldMotion.ts), so what sits under it moves on the same frames, and a close keeps the
// body drawn until it has folded away (Leo, 2026-11-07, on the folds: "they dont overshoot but they
// decelerate at the end. i think that might be the key"). The summary's click (mouse, Enter, Space)
// runs the fold instead of the browser's instant toggle; the element stays a real <details>, so its
// semantics and the summary's keyboard handling are the browser's. Reduce Motion, the pane's motion
// off or a hidden page: one frame. Its marker, where the page draws one, is the caller's CSS, turning
// on `[open]`; the body is open for the whole of a close, so a marker keyed to `data-fold-open` turns
// as the close starts.
import { useState, type DetailsHTMLAttributes, type HTMLAttributes, type ReactNode, type Ref } from "react";
import { useFoldMotion } from "../acpmux/session-info/foldMotion";

export interface FoldDetailsProps extends Omit<
  DetailsHTMLAttributes<HTMLDetailsElement>,
  "open" | "onToggle" | "children"
> {
  summary: ReactNode;
  summaryProps?: HTMLAttributes<HTMLElement> & Record<`data-${string}`, string | undefined>;
  /// Open at first (uncontrolled).
  defaultOpen?: boolean;
  /// Controlled: the owner's state. Set with `onOpenChange`.
  open?: boolean;
  onOpenChange?(open: boolean): void;
  /// The box that holds the body (its height moves).
  bodyClassName?: string;
  detailsRef?: Ref<HTMLDetailsElement>;
  children: ReactNode;
}

export function FoldDetails({
  summary,
  summaryProps,
  defaultOpen = false,
  open: controlled,
  onOpenChange,
  bodyClassName,
  detailsRef,
  children,
  ...details
}: FoldDetailsProps) {
  const [own, setOwn] = useState(defaultOpen);
  const open = controlled ?? own;
  const fold = useFoldMotion<HTMLDivElement>(open, () => 0);
  const apply = (next: boolean) => {
    if (controlled === undefined) setOwn(next);
    onOpenChange?.(next);
  };
  return (
    <details {...details} ref={detailsRef} open={fold.drawn} data-fold-open={open ? "" : undefined}>
      <summary
        {...summaryProps}
        onClick={(event) => {
          summaryProps?.onClick?.(event);
          if (event.defaultPrevented) return;
          // The fold, not the browser's instant toggle: the body stays drawn while it closes.
          event.preventDefault();
          fold.toggle(!open, apply);
        }}
      >
        {summary}
      </summary>
      <div ref={fold.ref} className={bodyClassName ?? "fold-details__body"}>
        {children}
      </div>
    </details>
  );
}
