// l10n-allow-file: gallery fixtures, not shipped UI.
// A newly delivered row shares the reader's scroll frame; it must already be fully drawn.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "./model";

const rows = Array.from({ length: 6 }, (_, index) => [
  user(`Check retry case ${index + 1}.`, 20 - index * 2, { id: `scroll-arrival-prompt-${index}` }),
  assistant(`Case ${index + 1} passed. The response keeps its place while history loads.`, 19 - index * 2, {
    id: `scroll-arrival-reply-${index}`,
  }),
]).flat();
const snapshot = chat(rows, { title: "Read earlier retry checks" });
const arrival = assistant("The next check passed too.", 1, { id: "scroll-arrival-new" });

const arrive =
  (input: "wheel" | "key" | "drag"): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="scroll-arrival-reply-5"]'));
    const scroller = ctx.find({ selector: ".acpmux-scroll" }) as HTMLElement;
    const bridge = (
      ctx.document.defaultView as unknown as {
        cmuxAcpmuxBridge?: { receive(snapshot: AcpmuxSnapshot): void };
      }
    ).cmuxAcpmuxBridge;
    if (!bridge) throw new Error("gallery pane bridge is unavailable");
    if (input === "wheel") scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -24, bubbles: true }));
    else if (input === "key") scroller.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true }));
    else scroller.dispatchEvent(new PointerEvent("pointerdown", { pointerId: 1, buttons: 1, bubbles: true }));
    scroller.scrollTop -= 24;
    bridge.receive({ ...structuredClone(snapshot), rows: [...rows, arrival] });
    await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="scroll-arrival-new"]'));
    const drawn = ctx.find({ selector: '[data-row-id="scroll-arrival-new"]' });
    if (drawn.matches(".cmux-load-fade, .acpmux-row--enter, .acpmux-row--message-enter"))
      throw new Error("a row arriving during scroll entered with a fade or transform");
    if (input === "drag")
      scroller.dispatchEvent(new PointerEvent("pointerup", { pointerId: 1, buttons: 0, bubbles: true }));
  };

export default agentPaneEntry({
  id: "agent-pane.scroll-arrival",
  title: "Transcript: rows arriving during a reader gesture",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript"],
  variants: {
    wheel: { note: "An arriving reply draws settled during an upward wheel step.", snapshot, play: arrive("wheel") },
    keyboard: { note: "The same settled arrival while Arrow Up moves the reader.", snapshot, play: arrive("key") },
    drag: { note: "The same settled arrival while the reader holds a scroll drag.", snapshot, play: arrive("drag") },
  },
});
