import React, { useContext } from "react";
import { AgentMark } from "../shared/AgentMark";
import { InQuietRow } from "./ComposerFoot";

// The quiet row's first item (Leo 2026-10-21: "why is there no harness at the left"): the chat's
// harness, its mark and its name ("Claude Code", "Codex"), where Claude Code's footer starts with
// its project. Quiet text in the row's secondary ink, no capsule; the soft pill on hover only when
// a click does something (composerLocation.css, `.acpmux-foot-harness`). Only the quiet row draws it
// (ComposerFoot's InQuietRow): the box's own row and the New Tab card's pickers already lead with the
// model's mark, so elsewhere it renders nothing, not a hidden button.
//
// A chat that can still change harness (a New Tab, a chat with no message yet) opens the model
// button's menu, whose rail is the composer's harness switcher (`openSwitcher`). A started chat's
// harness is fixed (ComposerPickers `locked`), so its item only names it: no button, no pill.
//
// In a narrow row the name goes first and the mark stays (composerRowFit.ts, the `harness` unit);
// the row's fit then names the harness in a tooltip.
export function ComposerHarness({
  mark,
  name,
  openSwitcher,
}: {
  /** The brand AgentMark draws (a profile's icon, its family or its id). */
  mark: string;
  name: string;
  /** Opens the harness switcher; undefined while the chat's harness is fixed. */
  openSwitcher?: () => void;
}) {
  const inQuietRow = useContext(InQuietRow);
  if (!inQuietRow) return null;
  const face = (
    <>
      <AgentMark agent={mark} size={15} />
      <span className="acpmux-foot-harness-name" data-fit-part="harness" data-fit-forms="full">
        {name}
      </span>
    </>
  );
  return (
    <span
      className="acpmux-picker acpmux-foot-harness"
      data-fit-title={name}
      data-fit-title-unit="harness"
      {...(openSwitcher ? {} : { "data-inert": "" })}
    >
      {openSwitcher ? (
        <button
          type="button"
          className="acpmux-picker-button acpmux-pill acpmux-foot-harness-face"
          aria-label={name}
          onClick={openSwitcher}
        >
          {face}
        </button>
      ) : (
        // Not a control: no `acpmux-picker-button` and no `acpmux-pill`, so nothing takes it for one
        // (no pill, no focus); composerLocation.css gives it the pill's box from the same tokens.
        <span className="acpmux-foot-harness-face">{face}</span>
      )}
    </span>
  );
}
