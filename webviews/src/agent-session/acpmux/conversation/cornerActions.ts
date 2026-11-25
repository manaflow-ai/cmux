// The class of every button in a block's corner toolbar: a code card's header, an edit's diff, a
// tool's output, a Shell block. It is a reply's Copy button (`.cv-iconbtn`, MessageActions.tsx): a
// bare glyph at rest and the hover fill on the button under the pointer, with the transcript's
// focus ring; `.cv-codeblock__action` only sizes it (conversation.css).
import { experimentArm } from "../../../experiments/experiment";
import { codeActionsLook } from "./codeActions.experiment";

const CORNER_ACTION = "cv-iconbtn cv-codeblock__action";

let looked = false;

/**
 * The corner button's class. The first call also marks the page with the gallery's arm of
 * `code-actions-look` (conversation.css `:root[data-code-actions]`; the shipped arm sets nothing).
 * It is read at the first render, not at import, because the gallery's stage installs the arm
 * after it has loaded the entry's modules.
 */
export function cornerAction(): string {
  if (!looked && typeof document !== "undefined") {
    looked = true;
    const arm = experimentArm(codeActionsLook);
    if (arm !== codeActionsLook.defaultArm) document.documentElement.dataset.codeActions = arm;
  }
  return CORNER_ACTION;
}
