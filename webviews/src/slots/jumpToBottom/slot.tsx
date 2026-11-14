// The transcript's Jump to latest mark as a theme slot (schemas/theme/slots.json `chat.jumpToBottom`):
// what the glass circle above the composer draws inside itself, and how that mark arrives, rests and
// answers a press. VirtualTranscript.tsx's JumpToLatest owns the button (its glass, place, fade, label
// and click); the slot draws only what is inside it.
import { defineSlot } from "../registry";

export type JumpToBottomProps = {
  /** The button is on screen (the reader is scrolled up from the latest message). It stays mounted
   * while hidden, so a variant can play its arrival off `.acpmux-jump-latest[data-shown]`. */
  shown: boolean;
  /** The agent is working: new content is still arriving below. */
  working: boolean;
};

export const jumpToBottomSlot = defineSlot<JumpToBottomProps>("chat.jumpToBottom");
