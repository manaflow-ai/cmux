// l10n-allow-file: gallery drafts and file names, not shipped copy.
import { useLayoutEffect, useRef } from "react";
import { componentEntry } from "../../gallery/format";
import { noChat, user } from "../../gallery/fixtures/acpmux";
import type { ComposerHandle } from "./Composer";
import type { TerminalPickersLook } from "./TerminalPickersNote";

/// The composer of a chat a cmux terminal runs (Toggle Terminal and Chat, with Write to a Chat a
/// Terminal Runs on): Send, Stop and attachments as in any chat, and in place of the model and mode
/// chips, which cannot apply there, where they are set. Each look of that (TerminalPickersNote.tsx),
/// idle, mid-turn (Stop) and with a file staged.
type Props = { look: TerminalPickersLook; working?: boolean; file?: boolean; draft?: string };

export default componentEntry<Props>({
  id: "agent-pane.terminal-chat-composer",
  title: "Composer of a chat a terminal runs",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 380, normal: 640, wide: 860 },
  covers: [
    "agent-session/acpmux/TerminalPickersNote.tsx#TerminalPickersNote",
    "agent-session/acpmux/Composer.tsx#Composer",
  ],
  load: async () => {
    const { Composer } = await import("./Composer");
    const { TerminalPickersNote } = await import("./TerminalPickersNote");
    return function GalleryTerminalChatComposer({ look, working = false, file = false, draft = "" }: Props) {
      const handle = useRef<ComposerHandle>(null);
      useLayoutEffect(() => {
        const staged = file
          ? [
              {
                id: "notes",
                kind: "text" as const,
                name: "notes.md",
                mimeType: "text/markdown",
                size: 412,
                text: "# Notes",
              },
            ]
          : [];
        handle.current?.restore(draft, staged);
      }, [draft, file]);
      const snapshot = noChat([], {
        sessionId: "gallery-terminal-chat",
        isWorking: working,
        summary: {
          sessionId: "gallery-terminal-chat",
          harness: "claude",
          cwd: "/demo/app",
          turnCount: 3,
          terminal: true,
        },
        rows: [user("Reply with the word ok", 1)],
      });
      return (
        <div className="acpmux-shell" style={{ display: "block", padding: "var(--space-4)" }}>
          <Composer
            handle={handle}
            snapshot={snapshot}
            sessionId={snapshot.sessionId}
            chips={() => <TerminalPickersNote look={look} />}
            onSend={() => true}
            onStop={() => {}}
            onProject={() => {}}
            onNewChat={() => {}}
            localName="studio"
            projectChoices={[{ cwd: "/demo/app", label: "app" }]}
          />
        </div>
      );
    };
  },
  variants: {
    sentence: {
      props: { look: "sentence" },
      note: "Before: the whole sentence where the chips stood; long, and the first thing a narrow pane cuts.",
    },
    badge: {
      props: { look: "badge" },
      note: "Picked: a terminal glyph and 'Set in terminal' at the chips' place and height; the sentence is its tooltip.",
    },
    trailing: {
      props: { look: "trailing" },
      note: "The badge at the row's end, where Claude and Codex keep the model; it crowds Stop and Send.",
    },
    "badge-working": {
      props: { look: "badge", working: true, draft: "and then run the tests" },
      note: "Mid-turn: Stop stops the terminal's turn; a send waits for it to end.",
    },
    "badge-file": {
      props: { look: "badge", file: true, draft: "Summarize this file" },
      note: "A file staged: it goes into the terminal's harness with the prompt.",
    },
  },
});
