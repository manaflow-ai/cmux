import { useId, type ReactNode } from "react";

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
