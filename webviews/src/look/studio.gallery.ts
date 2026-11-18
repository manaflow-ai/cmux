// l10n-allow-file: gallery fixtures (sample prompts), not shipped UI.
// The studio look (look/README.md), its two surfaces as the gallery draws them: a finished chat
// (the "project / chat title" breadcrumb, the prompt's dark pill, "Worked for", the composer with
// its placeholder, paperclip, model and round send) and the New Tab page (the minimal template:
// the composer card alone).
import { agentPaneEntry } from "../gallery/format";
import { assistant, chat, CWD, noChat, summary, user } from "../gallery/fixtures/acpmux";

export default agentPaneEntry({
  id: "look.studio",
  title: "studio look: chat and New Tab",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  covers: ["look/studio.css", "look/studio.ts"],
  variants: {
    chat: {
      note: "A finished chat: the breadcrumb, the dark prompt pill, Worked for, and the studio composer.",
      ready: { cwd: CWD },
      snapshot: chat([
        user("Add expiring share links to drafts", 3),
        assistant("Share links now expire after seven days; the dashboard shows when each one ends.", 1),
        summary(0.5, { status: "completed" }),
      ]),
    },
    "new-tab": {
      note: "The New Tab page on the minimal template: the composer card with the studio placeholder.",
      ready: {
        newTab: { kind: "agent", cwd: CWD, home: "/Users/you", lastAgent: "claude", template: "minimal" },
        newSession: true,
      },
      snapshot: noChat([]),
    },
  },
});
