// l10n-allow-file: deterministic gallery fixture labels, not shipped copy.
// A Queued entry at a turn's boundary (Leo, 2026-11-17: "i also dont like seeing the flicker flash of
// the Queued blah blah blah something"). Each arm plays the same timeline through the pane's own gate
// (queuedMessages.ts `useShownQueue`, afterDelay.ts `useSettledItems`): a prompt sent as the turn ends
// lives 180 ms in the queue, then a second one that really waits stays 1.2 s. The rows stand for the
// composer's queue row and the transcript's waiting card, which read the one gated list.
//
// Picked: `hold-200`. 200 ms is past the gap between a turn's end and the queue's drain, so the
// short entry never paints at all, and a real wait shows within a beat of the send. `hold-150-fade`
// still paints the 180 ms entry for 30 ms, faint: a softer flash, still a flash. `fade-only` paints
// every entry and fades it in and out: the short one reads as a blink, and the queue moves on each.
import { useEffect, useMemo, useRef, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxSnapshot } from "../model";
import { TRANSIENT_SHOW_MS } from "../afterDelay";
import { useShownQueue } from "./queuedMessages";

type Variant = "hold-200" | "hold-150-fade" | "fade-only";
type Queue = AcpmuxSnapshot["queue"];

const SHORT = { id: "q-short", prompt: "Also run the linter" };
const LONG = { id: "q-long", prompt: "Then open the PR against feat-cmux-next" };

/// The timeline, in ms from the start: [at, queue].
const STEPS: [number, Queue][] = [
  [0, []],
  [400, [SHORT]],
  [580, []],
  [1_000, [LONG]],
  [2_200, []],
];

const HOLD_MS: Record<Variant, number> = { "hold-200": TRANSIENT_SHOW_MS, "hold-150-fade": 150, "fade-only": 0 };
/// How long a leaving row fades out (`fade-only`), the host's fade-in token.
const LEAVE_MS = 120;

/// The queue as drawn, with leaving rows kept for their fade-out when `fadeOut`.
function useWithLeaving(queue: Queue, fadeOut: boolean): { entry: Queue[number]; leaving: boolean }[] {
  const [leaving, setLeaving] = useState<Queue>([]);
  const last = useRef<Queue>(queue);
  useEffect(() => {
    const gone = last.current.filter((entry) => !queue.some((now) => now.id === entry.id));
    last.current = queue;
    if (!fadeOut || gone.length === 0) return;
    setLeaving((now) => [...now, ...gone]);
    const timer = window.setTimeout(() => setLeaving((now) => now.filter((entry) => !gone.includes(entry))), LEAVE_MS);
    return () => window.clearTimeout(timer);
  }, [queue, fadeOut]);
  return useMemo(
    () => [
      ...queue.map((entry) => ({ entry, leaving: false })),
      ...leaving
        .filter((entry) => !queue.some((now) => now.id === entry.id))
        .map((entry) => ({ entry, leaving: true })),
    ],
    [queue, leaving],
  );
}

function Timeline({ variant }: { variant: Variant }) {
  const [queue, setQueue] = useState<Queue>([]);
  const [paints, setPaints] = useState<string[]>([]);
  useEffect(() => {
    const timers = STEPS.map(([at, next]) => window.setTimeout(() => setQueue(next), at));
    return () => timers.forEach((timer) => window.clearTimeout(timer));
  }, []);
  const shown = useShownQueue(queue, `queued-transient-${variant}`, HOLD_MS[variant]);
  const rows = useWithLeaving(shown, variant === "fade-only");
  useEffect(() => {
    for (const { entry } of rows) setPaints((now) => (now.includes(entry.id) ? now : [...now, entry.id]));
  }, [rows]);
  const fades = variant !== "hold-200";
  return (
    <>
      <ul className="queued-transient__queue" aria-label="Queued prompts">
        {rows.map(({ entry, leaving }) => (
          <li
            key={entry.id}
            className={
              "queued-transient__row" +
              (fades ? " cmux-load-fade" : "") +
              (leaving ? " queued-transient__row--leaving" : "")
            }
            data-prompt-id={entry.id}
          >
            <span className="queued-transient__label">Queued</span>
            <span>{entry.prompt}</span>
          </li>
        ))}
      </ul>
      <p className="queued-transient__paints" data-paints={paints.join(",")}>
        Painted: {paints.length ? paints.join(", ") : "nothing yet"}
      </p>
    </>
  );
}

function QueuedTransientGallery({ variant }: { variant: Variant }) {
  const [run, setRun] = useState(0);
  return (
    <main className="queued-transient-gallery" data-variant={variant} data-queued-transient>
      <header className="queued-transient-gallery__header">
        <div>
          <h1>A Queued entry at a turn's end</h1>
          <p>A prompt queued for 180 ms, then one that waits 1.2 s.</p>
        </div>
        <button type="button" className="ui-button" onClick={() => setRun((value) => value + 1)}>
          Replay
        </button>
      </header>
      <Timeline key={run} variant={variant} />
    </main>
  );
}

export default componentEntry<{ variant: Variant }>({
  id: "agent-pane.queued-transient",
  title: "Queued entries that come and go",
  area: "Agent pane",
  pane: true,
  height: 320,
  anchors: [{ selector: "[data-queued-transient]" }],
  covers: [
    "agent-session/acpmux/afterDelay.ts#useSettledItems",
    "agent-session/acpmux/conversation/queuedMessages.ts#useShownQueue",
    "agent-session/acpmux/ComposerQueue.tsx",
    "agent-session/acpmux/conversation/QueuedMessageCard.tsx",
  ],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("./QueuedTransient.gallery.css"),
    ]),
  load: async () => QueuedTransientGallery,
  variants: {
    "hold-200": {
      props: { variant: "hold-200" },
      note: "Picked: an entry shows only once it has stayed 200 ms, with no fade. The 180 ms prompt never paints; the one that waits shows 200 ms after it came and goes at once when it runs.",
    },
    "hold-150-fade": {
      props: { variant: "hold-150-fade" },
      note: "Held 150 ms, then a 120 ms fade-in: the 180 ms prompt still paints for 30 ms, faint. A softer flash, still a flash.",
    },
    "fade-only": {
      props: { variant: "fade-only" },
      note: "No hold: every entry fades in and out over 120 ms. The 180 ms prompt reads as a blink, and the queue moves on each.",
    },
  },
});
