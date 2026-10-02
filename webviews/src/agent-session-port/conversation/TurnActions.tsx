import { IconButton } from "./buttons";
import { Copy, TurnAnchor, TurnCopy, TurnFork } from "./icons";

/**
 * Buttons closing an assistant turn: `copy` (copy only), `fork` (copy, fork), `full` (copy, fork, anchor) or
 * `hidden` (Codex reserves the row's height while the buttons are hidden).
 */
export type TurnActionsKind = "copy" | "fork" | "full" | "hidden";

export function TurnActions({ kind }: { kind: TurnActionsKind }) {
  if (kind === "fork") {
    // Copy and "Fork chat from here" (a completed local turn, live captures).
    return (
      <div className="cv-turn-actions is-full">
        <IconButton label="Copy">
          <TurnCopy />
        </IconButton>
        <IconButton label="Fork chat from here">
          <TurnFork />
        </IconButton>
      </div>
    );
  }
  if (kind === "full") {
    return (
      <div className="cv-turn-actions is-full">
        <IconButton label="Copy">
          <TurnCopy />
        </IconButton>
        <IconButton label="Fork from here">
          <TurnFork />
        </IconButton>
        <IconButton label="Pin">
          <TurnAnchor />
        </IconButton>
      </div>
    );
  }
  return (
    <div className={`cv-turn-actions${kind === "hidden" ? " is-hidden" : ""}`}>
      <IconButton label="Copy">
        <Copy />
      </IconButton>
    </div>
  );
}
