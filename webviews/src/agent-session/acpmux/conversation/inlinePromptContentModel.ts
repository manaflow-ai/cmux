import type { PromptContentPart } from "../model";
import { blockText } from "./promptCollapse";

/** Whether a part the strip view keeps in the bubble gives it something to read: typed text with
 * more than space, a pasted block, a text file's body. */
export function readsAsText(part: PromptContentPart): boolean {
  return part.kind === "text" ? part.text.trim() !== "" : part.kind === "pasted" || Boolean(blockText(part));
}
