// l10n-allow-file: gallery fixtures (stage buttons, stand-in composer), not shipped UI.
// The capture bar (agent-session/acpmux/capture/CaptureBar.tsx) over a stand-in composer: the stage's
// Shortcut button is ⌃⇧⌘5, a target "takes" a screenshot a moment later and drops a chip in the
// composer, Record runs the timer until Stop, and the chip that lands is the recording (Leo,
// 2026-11-07: "could we also have a more native screenshot/screensharer (ergonomic one)/video
// recording of the app type thing/route?").
import { useReducer, useState, type CSSProperties } from "react";
import { CaptureBar, type CaptureBarActions } from "../../agent-session/acpmux/capture/CaptureBar";
import type { CaptureBarLook } from "../../agent-session/acpmux/capture/captureBar.experiment";
import { captureReducer, INITIAL_CAPTURE, type CapturePhase } from "../../agent-session/acpmux/capture/captureModel";

export function CaptureBarStage({ look, phase }: { look?: CaptureBarLook; phase?: CapturePhase["kind"] }) {
  const [state, send] = useReducer(captureReducer, {
    ...INITIAL_CAPTURE,
    phase:
      phase === "recording"
        ? { kind: "recording", startedAt: Date.now() - 12_000 }
        : phase === "open"
          ? { kind: "open" }
          : { kind: "closed" },
  });
  const [chips, setChips] = useState<string[]>([]);
  const land = (name: string) => {
    if (state.destination === "chat") setChips((now) => [...now, name]);
    send({ type: "done" });
  };
  const actions: CaptureBarActions = {
    shoot: (target) => {
      send({ type: "begin", what: target });
      setTimeout(() => land(`Screenshot (${target}).png`), 150);
    },
    record: () => {
      send({ type: "begin", what: "record" });
      setTimeout(() => send({ type: "recording", at: Date.now() }), 120);
    },
    stop: () => {
      send({ type: "stop" });
      setTimeout(() => land("Recording.mp4"), 200);
    },
    close: () => send({ type: "close" }),
    destination: (destination) => send({ type: "destination", destination }),
    option: (option, on) => send({ type: "option", option, on }),
  };
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100vh", background: "var(--agent-page-bg)" }}>
      <div
        style={{
          display: "flex",
          gap: "var(--ds-space-2)",
          padding: "var(--ds-space-2)",
          borderBottom: "1px solid var(--agent-border)",
        }}
      >
        <button type="button" data-stage="shortcut" onClick={() => send({ type: "toggle" })}>
          ⌃⇧⌘5
        </button>
        <output data-stage-phase="">{state.phase.kind}</output>
      </div>
      <main
        className="acpmux-main"
        data-dock="float"
        style={{ position: "relative", flex: 1, minHeight: 0, display: "flex", flexDirection: "column" }}
      >
        <div style={{ flex: 1 }} />
        <div className="acpmux-dock" style={{ "--cv-inset": "16px" } as CSSProperties}>
          <CaptureBar state={state} actions={actions} look={look} />
          <div className="acpmux-composer">
            <div
              className="acpmux-composer-box"
              data-stage-composer=""
              style={{
                display: "flex",
                flexWrap: "wrap",
                alignItems: "flex-start",
                gap: 8,
                margin: "0 16px 16px",
                minHeight: 72,
                borderRadius: 12,
                padding: 12,
                boxSizing: "border-box",
                background: "var(--acpmux-composer-tray)",
                boxShadow: "inset 0 0 0 1px var(--agent-border)",
                color: "var(--agent-muted)",
              }}
            >
              {chips.length === 0
                ? "Message"
                : chips.map((chip, index) => (
                    <span
                      key={index}
                      data-stage-chip=""
                      style={{
                        padding: "0 var(--ds-space-2)",
                        borderRadius: 6,
                        background: "var(--acpmux-question-hover)",
                        color: "var(--agent-text)",
                      }}
                    >
                      {chip}
                    </span>
                  ))}
            </div>
          </div>
        </div>
      </main>
    </div>
  );
}
