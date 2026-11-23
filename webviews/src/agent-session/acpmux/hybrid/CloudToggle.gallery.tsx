// l10n-allow-file: gallery fixtures (sample folders, models and prompts), not shipped UI.
//
// The cloud button by the composer (CloudToggle.tsx, RFD 0075). Leo, 2026-11-23: "somewhere in
// the composer area, either below it or slightly above it both in a chat and in the new tab page".
// Four placements (a chat or the New Tab page; the strip above the box or the quiet row under it),
// each in the three on-looks, plus off and waiting. The stage is a composer drawn from the real
// strip, box and foot classes; the button is live, so a click plays the turn-on.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { ComposerFoot } from "../ComposerFoot";
import { CloudToggle } from "./CloudToggle";
import { CloudTriToggle } from "./CloudTriToggle";
import {
  clicked,
  type HybridLook,
  type HybridPin,
  type HybridStart,
  type HybridStartLook,
  type HybridStartState,
  type HybridView,
} from "./hybridModel";

type Props = {
  /// A chat (composer at the pane's bottom) or the New Tab page (composer under the hero).
  page: "chat" | "newtab";
  /// The strip above the box, or the quiet row under it.
  spot: "above" | "below";
  look: HybridLook;
  state: "off" | "on" | "waiting";
  /// Under the box: the cloud alone, or with its name.
  form?: "chip" | "icon";
  /// The three-state control instead of the on/off cloud: its form and the mode it opens on.
  tri?: "segments" | "cycle";
  pin?: HybridPin;
  /// Parallel start: the step the button draws while the cloud computer boots, and how.
  start?: HybridStart;
  startLook?: HybridStartLook;
};

const VIEWS: Record<Props["state"], HybridView> = {
  off: { lit: false, pin: "auto", at: "local", used: 1, total: 3 },
  on: { lit: true, pin: "auto", at: "local", used: 2, total: 3 },
  waiting: { lit: false, waiting: true, pin: "auto", at: "local", used: 3, total: 3 },
};

const FAILED_REASON = "No cloud computer was free in this region.";

function Stage({ page, spot, look, state, form, tri, pin = "auto", start, startLook }: Props) {
  const [view, setView] = useState(VIEWS[state]);
  const [mode, setMode] = useState(pin);
  // The daemon's answer for this step: the chat is here until it is live.
  const begun: HybridStartState | undefined = start && {
    home: start === "live" ? "cloud" : "here",
    cloud: start,
    since: 0,
    reason: start === "failed" ? FAILED_REASON : undefined,
  };
  const toggle = tri ? (
    <CloudTriToggle
      pin={mode}
      look={look}
      form={tri}
      named={spot === "above" || tri === "cycle"}
      lit={view.lit}
      start={begun}
      startLook={startLook}
      onChange={setMode}
      onLitChange={(lit) => setView((now) => ({ ...now, lit }))}
    />
  ) : (
    <CloudToggle
      view={view}
      look={look}
      form={form ?? (spot === "above" ? "chip" : "icon")}
      start={begun}
      startLook={startLook}
      onChange={() => setView(clicked)}
    />
  );
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        justifyContent: page === "chat" ? "flex-end" : "flex-start",
        height: "100%",
        boxSizing: "border-box",
        padding: "0 12px 12px",
      }}
    >
      {page === "newtab" && <div style={{ flex: "0 0 30%" }} />}
      <form className="acpmux-composer" onSubmit={(event) => event.preventDefault()}>
        <div className="acpmux-composer-strip">
          <div className="acpmux-composer-context" style={{ display: "flex", alignItems: "center", gap: 4 }}>
            <span className="acpmux-location-readonly">atlas-web</span>
            <span className="acpmux-location-readonly">This Mac</span>
            {spot === "above" && toggle}
          </div>
        </div>
        <div className="acpmux-composer-box" data-gallery-box="">
          <textarea aria-label="Prompt" placeholder="Ask anything" rows={page === "newtab" ? 3 : 2} />
        </div>
        <ComposerFoot>
          <span className="acpmux-location-readonly">Ask before edits</span>
          <span style={{ flex: "1 1 auto" }} />
          {spot === "below" && toggle}
          <span className="acpmux-location-readonly">Opus 5.5 Medium</span>
        </ComposerFoot>
      </form>
    </div>
  );
}

const LOOK_NOTES: Record<HybridLook, string> = {
  rainbow: "Rainbow: the lit cloud is the rainbow, and an arc rises behind it once on turn-on.",
  sky: "Sky: one accent fill, the same arc in one color. The tasteful one.",
  aurora: "Aurora: the cloud in the text's ink over a soft rainbow light that blooms on turn-on.",
};
const SPOT_NOTES = {
  "chat-above": "A chat, above the box: a chip in the strip after the folder and machine.",
  "chat-below": "A chat, under the box: the cloud alone in the quiet row, before the model.",
  "newtab-above": "New Tab, above the box: the same chip, so a new chat starts already kept running.",
  "newtab-below": "New Tab, under the box: the cloud alone in the quiet row.",
} as const;

const variants: Record<string, { note: string; props: Props }> = {};
for (const page of ["chat", "newtab"] as const) {
  for (const spot of ["above", "below"] as const) {
    const where = `${page}-${spot}` as const;
    for (const look of ["rainbow", "sky", "aurora"] as const) {
      variants[`${where}-${look}`] = {
        note: `${SPOT_NOTES[where]} ${LOOK_NOTES[look]}`,
        props: { page, spot, look, state: "on" },
      };
    }
    variants[`${where}-off`] = {
      note: `${SPOT_NOTES[where]} Off: dull, fainter than the labels beside it. Click it to see the rainbow turn-on.`,
      props: { page, spot, look: "rainbow", state: "off" },
    };
    variants[`${where}-waiting`] = {
      note: `${SPOT_NOTES[where]} Every slot taken: a dashed outline, no color, until one frees.`,
      props: { page, spot, look: "rainbow", state: "waiting" },
    };
  }
  variants[`${page}-below-named`] = {
    note: `${SPOT_NOTES[`${page}-below`]} Alternative: with its name, for a first run when nobody knows the cloud yet.`,
    props: { page, spot: "below", look: "rainbow", state: "on", form: "chip" },
  };
}

// Leo, 11:08Z: the three-state control, a lead variant in every placement.
const lead: Record<string, { note: string; props: Props }> = {};
for (const page of ["chat", "newtab"] as const) {
  for (const spot of ["above", "below"] as const) {
    const where = `${page}-${spot}` as const;
    lead[`${where}-three-state`] = {
      note: `${SPOT_NOTES[where]} Lead: three states in one control. Hybrid (split cloud and computer, the default), Only in Cloud, Only on This Mac; the chosen one is lit.`,
      props: { page, spot, look: "rainbow", state: "off", tri: "segments" },
    };
    lead[`${where}-three-state-lit`] = {
      note: `${SPOT_NOTES[where]} The three-state control on Hybrid with its light on: this chat is high priority (Keep Running). Click Hybrid again to put it out.`,
      props: { page, spot, look: "rainbow", state: "on", tri: "segments" },
    };
    lead[`${where}-three-state-cloud`] = {
      note: `${SPOT_NOTES[where]} The three-state control on Only in Cloud, Sky look.`,
      props: { page, spot, look: "sky", state: "off", tri: "segments", pin: "cloud" },
    };
    lead[`${where}-three-state-cycle`] = {
      note: `${SPOT_NOTES[where]} Three states as one button: it shows the chosen glyph and name, and a click steps to the next.`,
      props: { page, spot, look: "rainbow", state: "off", tri: "cycle" },
    };
  }
}

// Parallel start (Leo, 11:17Z: "we don't have to wait for cloud machines to be up and running
// before we start a model ... start them all in parallel"). A chat with Cloud chosen runs on this
// Mac at once while its cloud computer boots, then moves. The button alone says so: three looks
// for the in-between steps, and one for a cloud computer that did not start.
const START_LOOK_NOTES: Record<HybridStartLook, string> = {
  fill: "Fill: the cloud fills left to right as the start goes on.",
  breathe: "Breathe: the outline takes the color and breathes; it fills softly as the chat moves.",
  words: "Words: the glyph stays quiet and the name steps Starting Here, Cloud Ready, Moving, In Cloud.",
};
const START_STEP_NOTES: Record<HybridStart, string> = {
  booting: "Booting: the chat already runs on this Mac; its cloud computer is starting.",
  ready: "Ready: the cloud computer is up; the chat moves at its next pause.",
  moving: "Moving: the chat is going to Cloud.",
  live: "Live: the chat is in Cloud, and the button is lit as usual.",
  failed:
    "Failed: the cloud computer did not start. A dull cloud with a small mark; the reason is in the tooltip, and the chat keeps running here.",
};
const starts: Record<string, { note: string; props: Props }> = {};
for (const where of ["chat-above", "newtab-above", "chat-below"] as const) {
  const [page, spot] = where.split("-") as [Props["page"], Props["spot"]];
  const base: Props = { page, spot, look: "rainbow", state: "off", tri: "segments", pin: "cloud" };
  for (const startLook of ["fill", "breathe", "words"] as const) {
    for (const start of ["booting", "ready", "moving", "live"] as const) {
      // Under the box one step per look is enough to judge the quiet row.
      if (spot === "below" && start !== "booting") continue;
      starts[`${where}-start-${startLook}-${start}`] = {
        note: `${SPOT_NOTES[where]} Only in Cloud, starting. ${START_LOOK_NOTES[startLook]} ${START_STEP_NOTES[start]}`,
        props: { ...base, start, startLook },
      };
    }
  }
  starts[`${where}-start-failed`] = {
    note: `${SPOT_NOTES[where]} ${START_STEP_NOTES.failed}`,
    props: { ...base, start: "failed" },
  };
  if (spot === "below") continue;
  starts[`${where}-start-hybrid-booting`] = {
    note: `${SPOT_NOTES[where]} Hybrid with its light on, starting: only the cloud half of the split glyph fills. ${START_STEP_NOTES.booting}`,
    props: { ...base, pin: "auto", state: "on", start: "booting", startLook: "fill" },
  };
  starts[`${where}-start-sky-moving`] = {
    note: `${SPOT_NOTES[where]} The fill in the Sky look, one accent color. ${START_STEP_NOTES.moving}`,
    props: { ...base, look: "sky", start: "moving", startLook: "fill" },
  };
  starts[`${where}-start-cloud-only-booting`] = {
    note: `${SPOT_NOTES[where]} The on/off cloud, starting. ${START_LOOK_NOTES.fill} ${START_STEP_NOTES.booting}`,
    props: { page, spot, look: "rainbow", state: "on", start: "booting", startLook: "fill" },
  };
}

export default componentEntry<Props>({
  id: "agent-pane.hybrid-cloud-toggle",
  title: "Hybrid chats: the cloud button",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 400, normal: 720 },
  covers: [
    "agent-session/acpmux/hybrid/CloudToggle.tsx",
    "agent-session/acpmux/hybrid/CloudTriToggle.tsx",
    "agent-session/acpmux/hybrid/cloudToggle.css",
    "agent-session/acpmux/hybrid/hybridModel.ts",
  ],
  load: async () => Stage,
  variants: { ...lead, ...starts, ...variants },
});
