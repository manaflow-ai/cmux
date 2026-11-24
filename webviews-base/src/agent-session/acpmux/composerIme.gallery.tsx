// l10n-allow-file: public-safe input-method fixtures, not shipped copy.
import { useLayoutEffect, useRef, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { noChat, user } from "../../gallery/fixtures/acpmux";

import type { ComposerHandle } from "./Composer";

type Props = { draft: string };

export default componentEntry<Props>({
  id: "agent-pane.composer-ime",
  title: "Composer input methods",
  area: "Agent pane",
  pane: true,
  height: 240,
  widths: { narrow: 400, normal: 640, wide: 860 },
  covers: ["agent-session/acpmux/Composer.tsx#Composer", "agent-session/acpmux/MarkdownField.tsx#MarkdownField"],
  load: async () => {
    const { Composer } = await import("./Composer");
    return function GalleryComposerIme({ draft }: Props) {
      const handle = useRef<ComposerHandle>(null);
      useLayoutEffect(() => {
        handle.current?.restore(draft, []);
      }, [draft]);
      const [sent, setSent] = useState<string[]>([]);
      const snapshot = noChat([], {
        sessionId: "gallery-ime",
        summary: { sessionId: "gallery-ime", harness: "claude", cwd: "/demo/app", turnCount: 1 },
        rows: [user("Add retries", 1)],
      });
      return (
        <div className="acpmux-shell" style={{ display: "block", padding: "var(--space-4)" }}>
          <Composer
            handle={handle}
            snapshot={snapshot}
            sessionId={snapshot.sessionId}
            chips={() => null}
            onSend={(text) => {
              setSent((previous) => [...previous, text]);
              return true;
            }}
            onStop={() => {}}
            onProject={() => {}}
            onNewChat={() => {}}
            localName="studio"
            projectChoices={[{ cwd: "/demo/app", label: "app" }]}
          />
          <output aria-label="Sent prompts">{JSON.stringify(sent)}</output>
        </div>
      );
    };
  },
  variants: {
    empty: {
      props: { draft: "" },
      note: "An empty composer with an observable send callback for input-method probes.",
    },
    korean: { props: { draft: "안녕하세요" }, note: "Korean input-method probe." },
    japanese: { props: { draft: "日本語" }, note: "Japanese input-method probe." },
    vietnamese: { props: { draft: "tiếng Việt" }, note: "Vietnamese input-method probe." },
  },
});
