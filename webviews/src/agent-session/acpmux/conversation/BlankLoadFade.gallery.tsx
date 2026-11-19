// l10n-allow-file: deterministic gallery fixture labels, not shipped copy.
// Blank to text (Leo, 2026-11-07, ask-69299b9711: "going from blank to text is more jarring than
// blank to fast fade in to text"). The chat opens before its read is in: the transcript is blank,
// then its rows land in two chunks (the first page, then the read). Each arm plays that sequence
// with one length or curve of the load fade (shared/loadFade.ts, desktop.css `cmux-load-fade`);
// `pop` is the old behaviour, the rows drawn in one frame. Replay mounts it again.
import { useEffect, useMemo, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { VirtualTranscript } from "../App";
import type { AcpmuxRow } from "../model";
import { MOTION_MS } from "../../../motion/scale.generated";

type Variant = "pop" | "micro" | "standard" | "large" | "linear" | "stagger";

const row = (id: string, kind: "user" | "assistant", text: string, at: number): AcpmuxRow => ({
  id,
  kind,
  text,
  version: 1,
  at,
});

const FIRST: AcpmuxRow[] = [
  row("load-user-1", "user", "Why does the pane open blank after a restart?", 1),
  row(
    "load-answer-1",
    "assistant",
    "The page shows before the daemon has answered the attach, so the transcript has nothing to draw for a moment.",
    2,
  ),
  row("load-user-2", "user", "Can it load faster?", 3),
  row(
    "load-answer-2",
    "assistant",
    "Usually it does: a kept tail draws on the first frame. When it cannot, the rows fade in instead of popping.",
    4,
  ),
];
const SECOND: AcpmuxRow[] = [
  row("load-user-3", "user", "And the rest of the chat?", 5),
  row("load-answer-3", "assistant", "The read lands right after and fades in the same way.", 6),
];

/// The chunks' timing: blank for a beat, the first page, then the read right after it.
const FIRST_AT = 400;
const READ_AT = 520;

/// The capture moment of the timed arms: the stage is ready once the read's last row is drawn and
/// its fade has settled (a play step settles on running animations), so a still shows the end
/// state on every run instead of whatever the timers had reached when the DOM first went quiet.
const LAST_ROW = SECOND[SECOND.length - 1]!.id;
const atEnd: Play = ({ waitFor, document }) =>
  waitFor(() => document.querySelector(`[data-blank-load-fade] [data-row-id="${LAST_ROW}"]`));

function Sequence({ variant, frozen }: { variant: Variant; frozen: boolean }) {
  const [step, setStep] = useState(0);
  // gallery-capture: the timed arms' play `atEnd` waits for the read's last row and its fade to settle.
  useEffect(() => {
    // The still: the rows land on the frame after the blank one and hold at the fade's midpoint.
    if (frozen) {
      setStep(2);
      return;
    }
    const first = window.setTimeout(() => setStep(1), FIRST_AT);
    const read = window.setTimeout(() => setStep(2), READ_AT);
    return () => {
      window.clearTimeout(first);
      window.clearTimeout(read);
    };
  }, [frozen]);
  const rows = useMemo(() => (step === 0 ? [] : step === 1 ? FIRST : [...FIRST, ...SECOND]), [step]);
  return (
    <VirtualTranscript
      rows={rows}
      sessionId={`blank-load-fade-${variant}`}
      onToggleActivity={() => {}}
      expanded={new Set()}
      working={false}
      loading={step < 2}
    />
  );
}

function BlankLoadFadeGallery({ variant, frozen = false }: { variant: Variant; frozen?: boolean }) {
  const [run, setRun] = useState(0);
  return (
    <main
      className="blank-load-fade-gallery"
      data-variant={variant}
      data-frozen={frozen ? "" : undefined}
      data-blank-load-fade
    >
      <header className="blank-load-fade-gallery__header">
        <div>
          <h1>Blank to text</h1>
          <p>The chat opens blank, then its rows land in two chunks.</p>
        </div>
        <button type="button" className="ui-button" onClick={() => setRun((value) => value + 1)}>
          Replay
        </button>
      </header>
      <div className="blank-load-fade-gallery__transcript">
        <Sequence key={run} variant={variant} frozen={frozen} />
      </div>
    </main>
  );
}

export default componentEntry<{ variant: Variant; frozen?: boolean }>({
  id: "agent-pane.blank-load-fade",
  title: "Blank to text: load fade",
  area: "Agent pane",
  pane: true,
  experimental: true,
  height: 520,
  anchors: [{ selector: "[data-blank-load-fade]" }],
  covers: [
    "agent-session/shared/loadFade.ts",
    "agent-session/acpmux/VirtualTranscript.tsx",
    "pages/shared/desktop.css#cmux-load-fade",
  ],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("./BlankLoadFade.gallery.css"),
    ]),
  load: async () => BlankLoadFadeGallery,
  variants: {
    micro: {
      props: { variant: "micro" },
      play: atEnd,
      note: `Selected: the host's fade-in token (micro, ${MOTION_MS.micro} ms), ease-out. Fast enough to read as a load, not an effect.`,
    },
    "micro-mid": {
      props: { variant: "micro", frozen: true },
      note: "The selected fade held at its midpoint, to show what one frame of it looks like.",
    },
    standard: {
      props: { variant: "standard" },
      play: atEnd,
      note: `${MOTION_MS.standard} ms (standard), ease-out: softer, starts to read as an animation.`,
    },
    large: {
      props: { variant: "large" },
      play: atEnd,
      note: `${MOTION_MS.large} ms (large), ease-out: the ceiling; visibly slow on a restart.`,
    },
    linear: {
      props: { variant: "linear" },
      play: atEnd,
      note: `${MOTION_MS.micro} ms, linear: the text stays faint longer before it is legible.`,
    },
    stagger: {
      props: { variant: "stagger" },
      play: atEnd,
      note: `${MOTION_MS.micro} ms with each row 16 ms after the last: reads as a cascade, not a load.`,
    },
    pop: { props: { variant: "pop" }, play: atEnd, note: "Before: no fade; the rows pop in from blank in one frame." },
  },
});
