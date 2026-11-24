// l10n-allow-file: gallery labels, not shipped UI.
// The composer's Stop when turns start and stop quickly (composer/turnPresence.ts, the Rust model's
// copy; Leo, 2026-11-22: "we ought to have a better fade in/fade out and maybe a pulse when you for
// some reason start stop quick. so that the composer isn't flickering with the stop button"). Each
// variant is one arm of experiment `stop-presence`, held at fixed points: the idle slot (its cell
// reserved), Stop, Stop lingering after a turn's end, the pulse when the next turn starts then, and
// Stop again; under them, a burst of turns run through the model, the chat's running state against
// what the slot draws.
import type React from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { MOTION_MS } from "../../../motion/scale.generated";
import { HOLD_MS, TurnPresence } from "./turnPresence";
import type { StopPresenceArm } from "./stopPresence.experiment";

type Props = { arm: StopPresenceArm; look: "claude" | "codex" };

/// The burst: a turn that ends and starts again 5 to 300 ms later, as a queued prompt, a steer or a
/// subagent's notice does, then a gap, then turns shorter than the dwell.
const BURST: Array<[number, boolean]> = [
  [100, true],
  [900, false],
  [905, true],
  [1300, false],
  [1340, true],
  [1700, false],
  [1990, true],
  [2400, false],
  [3200, true],
  [3260, false],
  [3500, true],
  [3580, false],
];
const SPAN_MS = 4400;

type Span = { from: number; to: number; on: boolean };

function spans(burst: Array<[number, boolean]>): { running: Span[]; shown: Span[]; pulses: number[] } {
  const model = new TurnPresence(false, 0);
  const running: Span[] = [];
  const shown: Span[] = [];
  const pulses: number[] = [];
  let runFrom = 0;
  let showFrom = 0;
  let next = 0;
  for (let at = 0; at <= SPAN_MS; at += 1) {
    const wasRunning = model.running;
    const wasShown = model.shown;
    const wasPulses = model.pulses;
    while (next < burst.length && burst[next]![0] === at) model.set(burst[next++]![1], at);
    model.advance(at);
    if (model.running !== wasRunning) {
      running.push({ from: runFrom, to: at, on: wasRunning });
      runFrom = at;
    }
    if (model.shown !== wasShown) {
      shown.push({ from: showFrom, to: at, on: wasShown });
      showFrom = at;
    }
    if (model.pulses !== wasPulses) pulses.push(at);
  }
  running.push({ from: runFrom, to: SPAN_MS, on: model.running });
  shown.push({ from: showFrom, to: SPAN_MS, on: model.shown });
  return { running, shown, pulses };
}

/// Stop shown, or not, never stands for less than the hold between two changes.
const holdKept: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelectorAll("[data-stop-span]").length > 0);
  const { shown } = spans(BURST);
  for (const span of shown.slice(1, -1))
    if (span.to - span.from < HOLD_MS)
      throw new Error(`Stop drew ${span.on ? "shown" : "gone"} for ${span.to - span.from} ms`);
  for (const button of ctx.document.querySelectorAll<HTMLElement>(".acpmux-send-slot")) {
    const box = button.getBoundingClientRect();
    if (Math.round(box.width) !== 28) throw new Error(`a send slot is ${box.width} px wide, not 28`);
  }
};

function StopFrame({
  arm,
  look,
  state,
  pulse,
}: {
  arm: StopPresenceArm;
  look: Props["look"];
  state: "idle" | "stop" | "linger";
  /// How far through the pulse's run (0 to 1), if one plays.
  pulse?: number;
}) {
  const ring =
    pulse !== undefined && arm === "ring"
      ? ({
          animation: "none",
          opacity: 0.5 * (1 - pulse),
          transform: `scale(${0.7 + 0.45 * pulse})`,
          boxShadow: "0 0 0 1.5px currentColor",
        } satisfies React.CSSProperties)
      : undefined;
  const bump = pulse !== undefined && arm === "bump" ? 1 + 0.15 * Math.sin(Math.PI * Math.min(1, pulse / 0.9)) : 1;
  return (
    <div
      className="acpmux-composer"
      data-composer-look={look === "codex" ? "codex" : undefined}
      style={{ display: "grid", placeItems: "center" }}
    >
      <span className="acpmux-composer-bar" style={{ display: "grid", placeItems: "center" }}>
        <span
          className="acpmux-send-slot"
          data-send-slot={state === "idle" ? "empty" : "filled"}
          style={{
            outline: "1px dashed color-mix(in srgb, var(--agent-muted) 35%, transparent)",
            outlineOffset: 2,
            borderRadius: 999,
          }}
        >
          {state !== "idle" && (
            <button
              type="button"
              tabIndex={-1}
              className="acpmux-send acpmux-cancel"
              data-stop-lingering={state === "linger" ? "" : undefined}
              aria-label={`Stop ${state}`}
              style={{ transition: "none" }}
            >
              <span style={{ display: "grid", transform: bump !== 1 ? `scale(${bump})` : undefined }}>
                {/* icon-scale-allow: the composer's own Stop glyph (ComposerPickers StopIcon). */}
                <svg
                  className="acpmux-icon"
                  width={18}
                  height={18}
                  viewBox="0 0 16 16"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth={1.25}
                  aria-hidden="true"
                >
                  <rect x="3.5" y="3.5" width="9" height="9" rx="1.5" />
                </svg>
              </span>
              {ring && <span className="acpmux-stop-pulse" style={ring} aria-hidden="true" />}
            </button>
          )}
        </span>
      </span>
    </div>
  );
}

function Timeline() {
  const { running, shown, pulses } = spans(BURST);
  const x = (ms: number) => (ms / SPAN_MS) * 100;
  const lane = (items: Span[], label: string, color: string) => (
    <div style={{ display: "grid", gridTemplateColumns: "112px 1fr", alignItems: "center", gap: "var(--ds-space-3)" }}>
      <div style={{ color: "var(--agent-muted)", fontSize: "var(--text-detail)" }}>{label}</div>
      <div
        style={{
          position: "relative",
          height: 14,
          background: "color-mix(in srgb, var(--agent-muted) 12%, transparent)",
          borderRadius: 4,
        }}
      >
        {items
          .filter((span) => span.on)
          .map((span) => (
            <span
              key={span.from}
              data-stop-span=""
              style={{
                position: "absolute",
                top: 0,
                bottom: 0,
                left: `${x(span.from)}%`,
                width: `${x(span.to - span.from)}%`,
                background: color,
                borderRadius: 4,
              }}
            />
          ))}
        {label === "Stop drawn" &&
          pulses.map((at) => (
            <span
              key={at}
              title="pulse"
              style={{
                position: "absolute",
                top: -4,
                left: `${x(at)}%`,
                transform: "translateX(-50%)",
                width: 6,
                height: 22,
                borderRadius: 4,
                background: "var(--agent-accent, var(--agent-text))",
              }}
            />
          ))}
      </div>
    </div>
  );
  return (
    <div style={{ display: "grid", gap: "var(--ds-space-2)", marginTop: "var(--ds-space-5)" }}>
      {lane(running, "Turn running", "var(--agent-muted)")}
      {lane(shown, "Stop drawn", "var(--agent-text)")}
      <div style={{ display: "grid", gridTemplateColumns: "112px 1fr", gap: "var(--ds-space-3)" }}>
        <span />
        <div style={{ color: "var(--agent-muted)", fontSize: "var(--text-caption)" }}>
          {SPAN_MS / 1000} s. Bars under "Stop drawn" are the only times the slot changes; ticks are pulses.
        </div>
      </div>
    </div>
  );
}

const COLUMNS = ["Idle", "Stop", "Turn ended", "Next turn 45 ms", "90 ms", "Stop"];

export default componentEntry<Props>({
  id: "agent-pane.composer-stop-presence",
  title: "Composer Stop: no flicker on quick turns",
  area: "Composer",
  pane: true,
  height: 420,
  widths: { normal: 640, narrow: 420 },
  keywords: ["stop", "flicker", "pulse", "hysteresis", "turn", "fade"],
  covers: [
    "agent-session/acpmux/composer/SendSlotGlyph.tsx#StopPulse",
    "agent-session/acpmux/composer/SendSlotGlyph.tsx#SendSlot",
  ],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../composerStates.css"),
      import("../composerLocation.css"),
      import("../composerLook.css"),
    ]).then(() => undefined),
  load: () =>
    Promise.resolve(function Gallery({ arm, look }: Props) {
      const pulseAt = (ms: number) => (arm === "fade" ? undefined : ms / MOTION_MS.standard);
      return (
        <div className="acpmux-shell" style={{ display: "block", height: "auto", padding: "var(--ds-space-5)" }}>
          <div
            style={{
              display: "grid",
              gridTemplateColumns: "repeat(6, 1fr)",
              gap: "var(--ds-space-3)",
              alignItems: "center",
            }}
          >
            {COLUMNS.map((label, index) => (
              <div
                key={index}
                style={{ color: "var(--agent-muted)", fontSize: "var(--text-caption)", textAlign: "center" }}
              >
                {label}
              </div>
            ))}
            <StopFrame arm={arm} look={look} state="idle" />
            <StopFrame arm={arm} look={look} state="stop" />
            <StopFrame arm={arm} look={look} state="linger" />
            <StopFrame
              arm={arm}
              look={look}
              state="stop"
              {...(pulseAt(45) !== undefined ? { pulse: pulseAt(45)! } : {})}
            />
            <StopFrame
              arm={arm}
              look={look}
              state="stop"
              {...(pulseAt(90) !== undefined ? { pulse: pulseAt(90)! } : {})}
            />
            <StopFrame arm={arm} look={look} state="stop" />
          </div>
          <Timeline />
        </div>
      );
    }),
  variants: {
    ring: {
      note: `Shipped. Stop fades in (${MOTION_MS.micro} ms) once a turn has run ${MOTION_MS.micro} ms, dims for ${MOTION_MS.large} ms after a turn's end, and a turn that starts in that window keeps it and grows a soft ring out of its box over ${MOTION_MS.standard} ms. The ring says "a new turn" without the glyph itself moving; Stop never shows or hides for under ${HOLD_MS} ms.`,
      props: { arm: "ring", look: "claude" },
      play: holdKept,
    },
    bump: {
      note: `The same presence, and the glyph swells to 115% and settles. Reads clearly, but a square that grows under the pointer looks like a press, and on a busy chat it bounces every few seconds.`,
      props: { arm: "bump", look: "claude" },
      play: holdKept,
    },
    fade: {
      note: `The same presence with no pulse: Stop dims at a turn's end and comes back to full when the next starts. The quietest; the restart reads only as the dim lifting, easy to miss.`,
      props: { arm: "fade", look: "claude" },
      play: holdKept,
    },
    "ring-codex": {
      note: "The shipped ring in Codex's look, where the slot is the round disc.",
      props: { arm: "ring", look: "codex" },
      play: holdKept,
    },
  },
});
