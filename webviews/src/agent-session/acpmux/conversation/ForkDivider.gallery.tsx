// l10n-allow-file: gallery fixtures (sample prompts, replies and model names), not shipped UI.
// A model switch's cut in the transcript (ForkDividerLine.tsx, conversation/forkDivider.ts; Leo
// 2026-11-11: "it looks like there's a line, and it's like, you know, forked from previous"). Each
// look sits between the Claude reply the chat had and the first Codex reply after the switch, in
// light and dark. The palettes stand in for what the app's applyTheme sets (as SinceDivider's
// gallery does); the component reads only theme tokens. References: chat apps' date and unread
// lines (a hairline with its words at the middle), and this pane's own New line (SinceDivider).
import type React from "react";
import { componentEntry } from "../../../gallery/format";
import { ForkDividerLine } from "./ForkDividerLine";

type Theme = "light" | "dark";
type Look = "before" | "hairline" | "chip" | "action";

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

function Line({ text }: { text: string }) {
  return <p style={{ margin: 0, color: "var(--agent-text)", lineHeight: "20px" }}>{text}</p>;
}

function ForkDividerLooks({ look, theme }: { look: Look; theme: Theme }) {
  return (
    <div
      className="acpmux-shell"
      style={{ ...THEMES[theme], padding: 16, display: "grid", gap: 16, minHeight: "100%" }}
    >
      <Line text="The upload retry now backs off on 5xx; tests pass." />
      {look === "before" ? (
        // What the pane drew before: Continue In…'s review in place of the chat, and after it a
        // sentence where the fork began.
        <div className="acpmux-muted">Forked from Fix upload retries. Everything above is from that chat.</div>
      ) : (
        <ForkDividerLine
          look={look === "chip" ? "chip" : "hairline"}
          divider={{
            label: "Forked from Claude Opus 5.5",
            ...(look === "action" && { openInTab: { sessionId: "fork", parentId: "chat" } }),
          }}
          onOpenInTab={() => undefined}
        />
      )}
      <Line text="Now check the retry jitter against the server's rate limit." />
      <Line text="GPT-6.1 Sol: the jitter stays under the limit at 40 requests a second; here is the run." />
    </div>
  );
}

export default componentEntry<{ look: Look; theme: Theme }>({
  id: "agent-pane.fork-divider",
  title: "Model switch: the Forked from line",
  area: "Agent pane",
  pane: true,
  height: 200,
  widths: { narrow: 420, normal: 760 },
  covers: ["agent-session/acpmux/conversation/ForkDividerLine.tsx#ForkDividerLine"],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  load: async () => ForkDividerLooks,
  variants: {
    before: {
      note: "Before: a sentence where the fork began, naming the chat, never the model it ran.",
      props: { look: "before", theme: "dark" },
    },
    hairline: {
      note: "A hairline across the column with Forked from Claude Opus 5.5 at its middle, in the notice's muted tone.",
      props: { look: "hairline", theme: "dark" },
    },
    chip: {
      note: "The label in a small boxed tag on the line: easier to spot, but a boxed label the transcript draws nowhere else.",
      props: { look: "chip", theme: "dark" },
    },
    action: {
      note: "Chosen: the hairline with Open in new tab after the label, the one way to move the switched chat to a tab of its own.",
      props: { look: "action", theme: "dark" },
    },
    "action-light": {
      note: "Chosen look in the light theme.",
      props: { look: "action", theme: "light" },
    },
    "hairline-light": {
      note: "The hairline in the light theme: the rule stays visible at the theme's 8% foreground.",
      props: { look: "hairline", theme: "light" },
    },
  },
});
