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
import { clicked, type HybridLook, type HybridView } from "./hybridModel";

type Props = {
  /// A chat (composer at the pane's bottom) or the New Tab page (composer under the hero).
  page: "chat" | "newtab";
  /// The strip above the box, or the quiet row under it.
  spot: "above" | "below";
  look: HybridLook;
  state: "off" | "on" | "waiting";
  /// Under the box: the cloud alone, or with its name.
  form?: "chip" | "icon";
};

const VIEWS: Record<Props["state"], HybridView> = {
  off: { lit: false, pin: "auto", at: "local", used: 1, total: 3 },
  on: { lit: true, pin: "auto", at: "local", used: 2, total: 3 },
  waiting: { lit: false, waiting: true, pin: "auto", at: "local", used: 3, total: 3 },
};

function Stage({ page, spot, look, state, form }: Props) {
  const [view, setView] = useState(VIEWS[state]);
  const toggle = (
    <CloudToggle
      view={view}
      look={look}
      form={form ?? (spot === "above" ? "chip" : "icon")}
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

export default componentEntry<Props>({
  id: "agent-pane.hybrid-cloud-toggle",
  title: "Hybrid chats: the cloud button",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 400, normal: 720 },
  covers: [
    "agent-session/acpmux/hybrid/CloudToggle.tsx",
    "agent-session/acpmux/hybrid/cloudToggle.css",
    "agent-session/acpmux/hybrid/hybridModel.ts",
  ],
  load: async () => Stage,
  variants,
});
