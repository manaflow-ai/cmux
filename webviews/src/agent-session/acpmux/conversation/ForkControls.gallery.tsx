// l10n-allow-file: gallery fixtures (sample prompts), not shipped UI.
// The Fork and Edit controls under each sent prompt, by what acpmux says the chat's agent can fork
// through (`forksAnyTurn`, messageMenu.ts). Leo, 2026-11-11: "why are only some chats forkable": a
// Claude Code chat on a profile under its own family name drew Fork on its latest prompt only, and
// Edit on none. Three prompts of one chat, each answered, with their footers shown as under the
// pointer, in light and dark:
//   - custom profile: a Claude Code profile named `claude-sr2`: Fork on every prompt, Edit on every
//     prompt after the first (the first has no turn before it to fork through);
//   - latest only: an agent that forks only from its latest reply: the earlier prompts keep a dimmed
//     Fork whose tooltip says why, the latest a live one, no Edit;
//   - latest only, pointed: the dimmed Fork under the pointer, its tooltip showing.
import type React from "react";
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";

type Theme = "light" | "dark";
type Props = { forkAny: boolean; theme: Theme };

// Apple System Colors, the app's default theme pair (gallery/theme/ghostty DEFAULT_*_THEME).
const THEMES: Record<Theme, React.CSSProperties> = {
  light: {
    "--agent-text": "#1d1d1f",
    "--agent-muted": "rgba(29, 29, 31, 0.6)",
    "--agent-page-bg": "#ffffff",
    colorScheme: "light",
    background: "#ffffff",
  } as React.CSSProperties,
  dark: {
    "--agent-text": "#f2f2f7",
    "--agent-muted": "rgba(242, 242, 247, 0.62)",
    "--agent-page-bg": "#1c1c1e",
    colorScheme: "dark",
    background: "#1c1c1e",
  } as React.CSSProperties,
};

const prompt = (index: number, text: string): AcpmuxRow => ({
  id: `user-${index}`,
  version: 1,
  at: minutesAgo(30 - index * 10),
  kind: "user",
  text,
});
const PROMPTS = [
  prompt(1, "Look at the upload retry path"),
  prompt(2, "Add tests for the 5xx case"),
  prompt(3, "Now update the docs"),
];
// Each prompt's own turn (its summary's seq), and the turn an Edit forks through (the one before).
const OWN = new Map(PROMPTS.map((row, index) => [row.id, (index + 1) * 4] as const));
const BEFORE = new Map(PROMPTS.slice(1).map((row, index) => [row.id, (index + 1) * 4] as const));

const pointDimmedFork: Play = async (ctx) => {
  await ctx.hover({ selector: '.cv-fork-button[data-fork-state="unavailable"]' });
};

export default componentEntry<Props>({
  id: "agent-pane.fork-controls",
  title: "Fork and Edit under each prompt",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 420, normal: 680 },
  anchors: [{ selector: ".cv-user__actions" }],
  covers: ["agent-session/acpmux/conversation/MessageActions.tsx#ForkButton"],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  load: async () => {
    const { UserBubble } = await import("./UserBubble");
    const { TurnActionsContext } = await import("./turnActions");
    return function GalleryForkControls({ forkAny, theme }: Props) {
      const actions = {
        fork: () => undefined,
        forkSeq: OWN.get(PROMPTS.at(-1)!.id),
        forkAny,
        promptTurns: OWN,
        ...(forkAny && { edit: { seqs: BEFORE, send: async () => true } }),
      };
      return (
        <div className="acpmux-shell" style={{ ...THEMES[theme], padding: 16, minHeight: "100%" }}>
          {/* Every prompt's footer as under the pointer, so all three rows read at once. */}
          <style>{`.cv-gallery-fork-controls .cv-user__actions { opacity: 1; }`}</style>
          <TurnActionsContext.Provider value={actions}>
            <div className="cv-gallery-fork-controls" style={{ display: "grid", gap: 24 }}>
              {PROMPTS.map((row) => (
                <div
                  key={row.id}
                  className="cv-user"
                  style={{ position: "relative", display: "flex", flexDirection: "column", alignItems: "flex-end" }}
                >
                  <UserBubble row={row} text={row.text ?? ""} />
                </div>
              ))}
            </div>
          </TurnActionsContext.Provider>
        </div>
      );
    };
  },
  variants: {
    "custom-profile": {
      note: "A Claude Code profile under its own family name (claude-sr2): Fork on every prompt, Edit on the second and third.",
      props: { forkAny: true, theme: "dark" },
    },
    "custom-profile-light": {
      note: "The same chat in the light theme.",
      props: { forkAny: true, theme: "light" },
    },
    "latest-only": {
      note: "An agent that forks only from its latest reply: the earlier prompts keep a dimmed Fork, the latest a live one; no Edit.",
      props: { forkAny: false, theme: "dark" },
    },
    "latest-only-light": {
      note: "The same chat in the light theme.",
      props: { forkAny: false, theme: "light" },
    },
    "latest-only-pointed": {
      note: "The dimmed Fork under the pointer: its tooltip says this agent can fork only from its latest reply.",
      props: { forkAny: false, theme: "dark" },
      play: pointDimmedFork,
    },
  },
});
