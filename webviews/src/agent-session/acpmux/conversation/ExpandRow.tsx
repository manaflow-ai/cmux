// The Show more / Show less row under every block the transcript cuts: an edit's diff, a Shell
// block, a file read, a call's output, a search's files, a long sent prompt or agent message. It is
// one button as wide as its block and the block's whole bottom row (Leo, 2026-11-07: "what if the
// whole bottom row area were clickable in this, like, show more show less area? ... my mouse is in
// the general vicinity, it's in the general height area"), on the block's own surface so a cut
// block's last lines fade straight into it. Under the pointer it only tints and its words go to full
// ink: no size, padding, border or weight changes (conversation.css `.cv-expand-row`).
import type { Ref } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { expandRowLook } from "./expandRow.experiment";

let looked = false;

/// Marks the page with the gallery's arm of `expand-row-look` the first time a row draws
/// (conversation.css `:root[data-expand-row]`; the shipped arm sets nothing). Read at render, not at
/// import: the gallery's stage installs the arm after it has loaded the entry's modules.
function markLook() {
  if (looked || typeof document === "undefined") return;
  looked = true;
  const arm = experimentArm(expandRowLook);
  if (arm !== expandRowLook.defaultArm) document.documentElement.dataset.expandRow = arm;
}

export function ExpandRow({
  open,
  label,
  onToggle,
  className,
  controls,
  buttonRef,
}: {
  /** Whether the block is open (Show less). */
  open: boolean;
  label: string;
  onToggle: () => void;
  /** The block's own class for the row (its place in the block: `cv-output-more`, `cv-user__more`). */
  className?: string;
  /** The id of what it opens. */
  controls?: string;
  buttonRef?: Ref<HTMLButtonElement>;
}) {
  markLook();
  return (
    <button
      ref={buttonRef}
      type="button"
      className={className ? `cv-expand-row ${className}` : "cv-expand-row"}
      aria-expanded={open}
      aria-controls={controls}
      // Its words are a control's, not the transcript's: Find skips them.
      data-find-skip=""
      onClick={onToggle}
    >
      <span className="cv-expand-row__label">{label}</span>
    </button>
  );
}
