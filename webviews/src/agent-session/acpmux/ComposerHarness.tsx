import React from "react";
import { AgentMark } from "../shared/AgentMark";

// The quiet row's first item (Leo 2026-10-21: "why is there no harness at the left"): the chat's
// harness, its mark and its name ("Claude Code", "Codex"), where Claude Code's footer starts with
// its project. Quiet text in the row's secondary ink, no capsule; the soft pill on hover only when
// a click does something (composerLocation.css, `.acpmux-harness`).
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
  const face = (
    <>
      <AgentMark agent={mark} size={15} />
      <span className="acpmux-harness-name" data-fit-part="harness" data-fit-forms="full">
        {name}
      </span>
    </>
  );
  return (
    <span
      className="acpmux-picker acpmux-harness"
      data-fit-title={name}
      data-fit-title-unit="harness"
      {...(openSwitcher ? {} : { "data-inert": "" })}
    >
      {openSwitcher ? (
        <button type="button" className="acpmux-picker-button" aria-label={name} onClick={openSwitcher}>
          {face}
        </button>
      ) : (
        <span className="acpmux-picker-button">{face}</span>
      )}
    </span>
  );
}
