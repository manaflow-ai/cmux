// l10n-allow-file: deterministic gallery fixture labels, not shipped copy.
// Leo, 2026-11-08 (ask-157340f908): "if you're not at the bottom ... there's a little animation where
// it appears to jump over your composer and then tuck under it ... it kind of, like, waterfalls over
// the composer if you think of the composer as a bar, that they go, like, over and then under
// behind." A prompt sent while the transcript is scrolled up (conversation/sendTuck.ts): the composer
// clears at once and a small copy of what went arcs over its top edge and drops behind the bar.
// `arc` is the product's; `funnel`, `drop` and `none` (the composer just clears, the before) are for
// comparison, through `data-send-tuck`. `rides` shows the open question: by default a scrolled-up
// send still glides the view to the latest row (sendScrollSetting.ts), and the prompt tucks then too.
import { useLayoutEffect, useRef, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { SCREEN_RECORDING_POSTER_JPEG } from "../../../gallery/fixtures/videoPoster";
import { tuckContent, tuckSent, type SendTuckStyle } from "./sendTuck";

const IMAGE = `data:image/jpeg;base64,${SCREEN_RECORDING_POSTER_JPEG}`;
const PROMPT = "can you check why this flickers on resize";
const HISTORY = [
  ["user", "Can you look at why the nightly failed?"],
  ["assistant", "The notarize step timed out; the build itself passed. I reran it and it went through."],
  ["user", "ok, and the flaky resize test?"],
  ["assistant", "It reads the pane's height before the first layout. I moved the read after the layout pass."],
  ["user", "nice. anything else on the board?"],
  ["assistant", "Two reviews waiting on you, and the docs job is red on base (not ours)."],
  ["user", "what changed in the composer this week?"],
  ["assistant", "The send motion: one clock for the bubble, its room and the thread's rise."],
] as const;

function Row({ kind, text }: { kind: string; text: string }) {
  return kind === "user" ? (
    <div className="cv-user" style={{ display: "flex", justifyContent: "flex-end", padding: "4px 16px" }}>
      <div className="ui-glass cv-user__bubble">{text}</div>
    </div>
  ) : (
    <p className="cv-assistant" style={{ margin: 0, padding: "4px 16px", color: "var(--cv-text)" }}>
      {text}
    </p>
  );
}

function SendTuckGallery({ variant, rides = false }: { variant: SendTuckStyle; rides?: boolean }) {
  const scroll = useRef<HTMLDivElement>(null);
  const box = useRef<HTMLDivElement>(null);
  const [draft, setDraft] = useState(true);
  const [sent, setSent] = useState(0);
  // Scrolled up: the reader is reading the start of the chat.
  useLayoutEffect(() => {
    if (scroll.current) scroll.current.scrollTop = 0;
  }, []);
  useLayoutEffect(() => {
    if (rides && sent > 0) scroll.current?.scrollTo({ top: scroll.current.scrollHeight, behavior: "smooth" });
  }, [rides, sent]);
  const send = () => {
    if (!draft) return;
    tuckSent(box.current, tuckContent(box.current, PROMPT));
    setDraft(false);
    setSent((count) => count + 1);
  };
  return (
    <div className="acpmux-shell" data-send-tuck={variant} data-send-tuck-gallery style={{ height: "100%" }}>
      <div className="acpmux-main" data-dock="float" style={{ position: "relative", height: "100%" }}>
        <div className="acpmux-stage" style={{ height: "100%" }}>
          <div ref={scroll} className="acpmux-scroll" style={{ height: "100%", overflow: "auto" }}>
            {[...HISTORY, ...HISTORY].map(([kind, text], index) => (
              <Row key={index} kind={kind} text={text} />
            ))}
            {Array.from({ length: sent }, (_, index) => (
              <Row key={`sent-${index}`} kind="user" text={PROMPT} />
            ))}
            {/* Room under the last row for the composer laid over the transcript's foot. */}
            <div aria-hidden style={{ blockSize: 140 }} />
          </div>
        </div>
        <div className="acpmux-dock">
          <form
            className="acpmux-composer"
            style={{ padding: "0 16px 12px" }}
            onSubmit={(event) => {
              event.preventDefault();
              send();
            }}
          >
            <div
              ref={box}
              className="ui-glass ui-glass-floats ui-glass-material acpmux-composer-box"
              style={{ display: "flex", alignItems: "center", gap: 8, padding: "8px 12px" }}
            >
              <div className="acpmux-composer-prompt" style={{ flex: 1, minWidth: 0 }}>
                <div contentEditable suppressContentEditableWarning style={{ outline: "none", minHeight: 20 }}>
                  {draft ? (
                    <>
                      <span className="acpmux-attachment acpmux-attachment-image" contentEditable={false}>
                        <img
                          src={IMAGE}
                          alt=""
                          style={{ width: 28, height: 28, objectFit: "cover", borderRadius: 6 }}
                        />
                      </span>{" "}
                      {PROMPT}
                    </>
                  ) : null}
                </div>
              </div>
              <button type="submit" className="ui-button acpmux-send" disabled={!draft}>
                Send
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
  );
}

export default componentEntry<{ variant: SendTuckStyle; rides?: boolean }>({
  id: "agent-pane.send-tuck",
  title: "Scrolled-up send tuck",
  area: "Agent pane",
  pane: true,
  experimental: true,
  height: 520,
  anchors: [{ selector: "[data-send-tuck-gallery]" }],
  covers: ["agent-session/acpmux/conversation/sendTuck.ts", "agent-session/acpmux/bottomStack.css#SEND-TUCK"],
  styles: () =>
    Promise.all([import("../styles.css"), import("../bottomStack.css"), import("../conversation/conversation.css")]),
  load: async () => SendTuckGallery,
  variants: {
    arc: {
      props: { variant: "arc" },
      note: "Selected: the view stays; Send, and the prompt hops over the composer's edge, drifting toward the sent side, and drops behind the bar.",
    },
    "arc-rides": {
      props: { variant: "arc", rides: true },
      note: "Today's default ride: the view glides to the latest row while the prompt tucks (open question).",
    },
    funnel: {
      props: { variant: "funnel" },
      note: "Narrows toward a point on the edge as it goes under (a small genie squeeze).",
    },
    drop: { props: { variant: "drop" }, note: "Lifts straight up over the edge and slides straight under." },
    none: { props: { variant: "none" }, note: "Before: the composer just clears." },
  },
});
