// l10n-allow-file: deterministic gallery fixture labels, not shipped copy.
// Sent Prompt Placement (chatDisplay.ts SEND_PLACEMENT_KEY, conversation/sendSeat.ts). Leo, 2026-11-22:
// "the wider sweeping situation with having there be a bunch of extra space at the bottom is not
// something we need to emulate (other than our claude code customization emulation repo) but... dang
// it's CUTE and so much NICER FEELING than just a jarring instant send". `latest` is the default and
// today's follow; `top` is the Claude Code look's: the sent prompt sweeps up to the top of the view
// (the thread on the compositor, over the large step) while it pops (conversation.css SEND-POP), and
// the room under it stays empty for the reply. `top-at-once` is Claude's own desktop app, whose
// scroll lands in one frame (Leo's recordings, 2026-11-22 2.37.32 and 2.39.45: no frame between).
// `top-long` streams a reply past the view's foot, where the view follows it again; `top-1000` seats
// a prompt under 1000 turns.
import { useEffect, useMemo, useState } from "react";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { VirtualTranscript } from "../App";
import type { SendPlacement } from "../chatDisplay";
import type { AcpmuxRow } from "../model";
import { THINKING } from "./turns";

type Props = { placement: SendPlacement; glide?: "off"; turns?: number; longReply?: boolean };

const row = (id: string, kind: "user" | "assistant", text: string, at: number): AcpmuxRow => ({
  id,
  kind,
  text,
  version: 1,
  at,
});

const ANSWERS = [
  "The notarize step timed out; the build itself passed.",
  "Everything on the board is green again, and the nightly picked up the fix.",
  "I reran the flaky test twenty times on the fleet: it passes every time now.",
];

function history(turns: number): AcpmuxRow[] {
  const rows: AcpmuxRow[] = [];
  for (let turn = 0; turn < turns; turn += 1) {
    const at = minutesAgo(Math.max(1, turns - turn));
    rows.push(row(`seat-user-${turn}`, "user", `Turn ${turn + 1}: can you look at why the nightly failed?`, at));
    rows.push(row(`seat-answer-${turn}`, "assistant", ANSWERS[turn % ANSWERS.length]!, at));
  }
  return rows;
}

const PROMPT = "and the send behaviour too... the wider sweeping situation with a bunch of extra space at the bottom";
const REPLY_LINE = "Here is what changed in the send path, step by step, with the numbers from the bench. ";

function SendPlacementGallery({ placement, glide, turns = 4, longReply }: Props) {
  const [sends, setSends] = useState(0);
  // The streamed reply's length in lines (`top-long`): it grows a line every 120 ms after a send.
  const [lines, setLines] = useState(0);
  const past = useMemo(() => history(turns), [turns]);
  useEffect(() => {
    if (!longReply || sends === 0) return;
    setLines(0);
    const timer = setInterval(() => setLines((value) => (value >= 40 ? value : value + 1)), 120);
    return () => clearInterval(timer);
  }, [longReply, sends]);
  const rows = useMemo(() => {
    const sent: AcpmuxRow[] = [];
    for (let index = 1; index <= sends; index += 1) {
      sent.push(row(`seat-sent-${index}`, "user", PROMPT, GALLERY_NOW));
      if (index === sends && longReply && lines > 0)
        sent.push({
          ...row(`seat-reply-${index}`, "assistant", REPLY_LINE.repeat(lines), GALLERY_NOW),
          version: lines,
        });
    }
    const thinking = { id: "seat-thinking", version: 1, at: GALLERY_NOW, kind: THINKING, below: true } as AcpmuxRow;
    return [...past, ...sent, ...(sends > 0 ? [thinking] : [])];
  }, [past, sends, longReply, lines]);
  return (
    <main className="message-entrance-gallery" data-follow-glide={glide} data-send-placement-gallery>
      <header className="message-entrance-gallery__header">
        <div>
          <h1>Sent prompt placement: {placement}</h1>
          <p>
            {placement === "top"
              ? "Send a prompt: it sweeps up to the top and the room under it waits for the reply."
              : "Send a prompt: it lands over the composer, as today."}
          </p>
        </div>
        <button
          type="button"
          className="ui-button"
          data-send-placement-send
          onClick={() => setSends((value) => value + 1)}
        >
          Send prompt
        </button>
      </header>
      <div className="message-entrance-gallery__transcript">
        <div className="acpmux-shell" style={{ height: "100%" }}>
          <VirtualTranscript
            rows={rows}
            sessionId={`send-placement-${placement}${glide ? "-at-once" : ""}-${turns}${longReply ? "-long" : ""}`}
            onToggleActivity={() => {}}
            expanded={new Set()}
            working={sends > 0}
            sends={sends}
            sendPlacement={placement}
          />
        </div>
      </div>
    </main>
  );
}

/// Sends once and waits for the sweep (the large step) and the pop (450 ms) to rest.
const sendOnce: Play = async (ctx) => {
  await ctx.click({ selector: "[data-send-placement-send]" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-row-id^="seat-sent-"], .acpmux-user'), { capMs: 2000 });
  await new Promise((resolve) => setTimeout(resolve, 600));
};

export default componentEntry<Props>({
  id: "agent-pane.send-placement",
  title: "Sent prompt placement",
  area: "Agent pane",
  pane: true,
  height: 560,
  anchors: [{ selector: "[data-send-placement-gallery]" }],
  covers: [
    "agent-session/acpmux/conversation/sendSeat.ts",
    "agent-session/acpmux/conversation/followGlide.ts",
    "agent-session/acpmux/chatDisplay.ts#SEND_PLACEMENT_KEY",
  ],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("./MessageEntrance.gallery.css"),
    ]),
  load: async () => SendPlacementGallery,
  variants: {
    latest: {
      props: { placement: "latest" },
      play: sendOnce,
      note: "Default (Above the Composer): the sent prompt lands over the composer, as today.",
    },
    top: {
      props: { placement: "top" },
      play: sendOnce,
      note: "Claude Code look (Top of the Chat): the thread sweeps up over 240 ms on the settle curve, the prompt pops and rests 20 px under the top, the room under it empty.",
    },
    "top-at-once": {
      props: { placement: "top", glide: "off" },
      play: sendOnce,
      note: "Claude's desktop app as recorded: the same seat, the scroll in one frame; only the pop moves.",
    },
    "top-long": {
      props: { placement: "top", longReply: true },
      play: sendOnce,
      note: "A reply that streams past the view's foot fills the room, then the view follows it as today.",
    },
    "top-1000": {
      props: { placement: "top", turns: 1000 },
      play: sendOnce,
      note: "1000 turns above: the seat reads only the current turn's rows, and the sweep is one compositor animation.",
    },
  },
});
