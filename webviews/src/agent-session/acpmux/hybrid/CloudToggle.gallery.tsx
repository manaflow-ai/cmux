// l10n-allow-file: gallery fixtures (sample folders, models and prompts), not shipped UI.
//
// The cloud button by the composer (CloudToggle.tsx, RFD 0078). Leo, 2026-11-23: "somewhere in
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
  type HybridBlockedWhy,
  type HybridLook,
  type HybridPin,
  type HybridView,
  type SlotHolder,
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
  /// A first run's blocked state: the name says it, a click goes to `onBlockedClick`.
  blocked?: HybridBlockedWhy;
  /// Every slot taken: the chats holding them, in the name's menu (drawn open).
  holders?: SlotHolder[];
  /// Where the chat runs now, after the name (the app's place state in the real mount).
  where?: string;
};

const HOLDERS: SlotHolder[] = [
  { session: "s-1", title: "Fix flaky login test" },
  { session: "s-2", title: "Migrate billing to v2 API" },
  { session: "s-3", title: "Nightly crash triage" },
];

const VIEWS: Record<Props["state"], HybridView> = {
  off: { lit: false, pin: "auto", at: "local", used: 1, total: 3 },
  on: { lit: true, pin: "auto", at: "local", used: 2, total: 3 },
  waiting: { lit: false, waiting: true, pin: "auto", at: "local", used: 3, total: 3 },
};

function Stage({ page, spot, look, state, form, tri, pin = "auto", blocked, holders, where }: Props) {
  const [view, setView] = useState(VIEWS[state]);
  const [mode, setMode] = useState(pin);
  const [held, setHeld] = useState(holders);
  const toggle = tri ? (
    <CloudTriToggle
      pin={mode}
      look={look}
      form={tri}
      named={spot === "above" || tri === "cycle"}
      lit={view.lit}
      waiting={view.waiting}
      where={where}
      blocked={blocked ? { why: blocked } : undefined}
      onBlockedClick={() => undefined}
      holders={held}
      onTrade={() => {
        setHeld(undefined);
        setView((now) => ({ ...now, waiting: false, lit: true }));
      }}
      holdersOpen={holders !== undefined}
      onChange={setMode}
      onLitChange={(lit) => setView((now) => ({ ...now, lit }))}
    />
  ) : (
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
    lead[`${where}-three-state-waiting`] = {
      note: `${SPOT_NOTES[where]} The three-state control when Keep Running was asked for and every slot is taken: the name says it waits, and the tooltip names the slots.`,
      props: { page, spot, look: "rainbow", state: "waiting", tri: "segments" },
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

// The first-run review (2026-11-23): what a brand-new user meets. Each `why` named on the control,
// and the full-slots menu. The app decides which applies; these draw each one.
const BLOCKED_NOTES: Record<HybridBlockedWhy, string> = {
  "signed-out": "Not signed in: the name asks to sign in, the cloud is dull; a click opens sign-in.",
  "no-plan": "Signed in, no plan: the name offers the free trial; a click opens Cloud setup.",
  "no-cloud": "A plan but no Cloud machine yet: a click opens Cloud setup.",
  "hours-spent": "The plan's Cloud hours are used up: a click opens the plan.",
  "trial-ended": "The free trial is over: a click opens the plan.",
  offline: "This Mac cannot reach Cloud: the warning dot on the cloud; a click tries again.",
  "move-failed": "The last move failed: the warning dot on the cloud; a click shows why and offers Retry.",
  slept: "Reopened after this Mac slept and the chat paused: the name says so; a click turns on Keep Running.",
  "trial-full": "Cloud's free trials are full for today: the tooltip says try tomorrow or start a plan.",
};
const firstRun: Record<string, { note: string; props: Props; height?: number }> = {};
for (const why of Object.keys(BLOCKED_NOTES) as HybridBlockedWhy[]) {
  firstRun[`chat-above-three-state-blocked-${why}`] = {
    note: `${SPOT_NOTES["chat-above"]} ${BLOCKED_NOTES[why]}`,
    props: { page: "chat", spot: "above", look: "rainbow", state: "off", tri: "segments", blocked: why },
  };
}
for (const why of ["signed-out", "no-plan"] as const) {
  firstRun[`newtab-above-three-state-blocked-${why}`] = {
    note: `${SPOT_NOTES["newtab-above"]} Where a new user meets it first. ${BLOCKED_NOTES[why]}`,
    props: { page: "newtab", spot: "above", look: "rainbow", state: "off", tri: "segments", blocked: why },
  };
}
for (const [id, where, pin, note] of [
  ["mac", "This Mac", "auto", "Hybrid, running on this Mac"],
  ["cloud", "atlas-web-cloud", "auto", "Hybrid, running on its Cloud machine"],
  ["moving", "Moving to atlas-web-cloud", "auto", "Hybrid while the chat moves"],
  ["pinned", "atlas-web-cloud", "cloud", "Only in Cloud, naming the machine"],
] as const) {
  firstRun[`chat-above-three-state-where-${id}`] = {
    note: `${SPOT_NOTES["chat-above"]} ${note}: the place after the name is the one the app reports, so the choice shows what it did.`,
    props: {
      page: "chat",
      spot: "above",
      look: "rainbow",
      state: id === "mac" ? "off" : "on",
      tri: "segments",
      pin,
      where,
    },
  };
}
firstRun["chat-above-three-state-full-holders"] = {
  note: `${SPOT_NOTES["chat-above"]} Keep Running asked for and every slot taken: the name opens the chats holding the slots, each with Give This Chat Its Slot.`,
  props: { page: "chat", spot: "above", look: "rainbow", state: "waiting", tri: "segments", holders: HOLDERS },
  // Tall enough for the open menu above the strip.
  height: 400,
};

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
  variants: { ...lead, ...firstRun, ...variants },
});
