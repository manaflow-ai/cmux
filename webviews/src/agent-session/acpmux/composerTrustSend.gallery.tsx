// l10n-allow-file: public-safe gallery drafts and trust fixtures, not shipped copy.
import { useLayoutEffect, useRef, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { noChat, user } from "../../gallery/fixtures/acpmux";
import type { ComposerHandle } from "./Composer";

type Props = { state: "reading" | "ask" | "folder" };

export default componentEntry<Props>({
  id: "agent-pane.composer-trust-send",
  title: "Composer trust loading",
  area: "Agent pane",
  pane: true,
  height: 240,
  widths: { narrow: 400, normal: 640, wide: 860 },
  covers: ["agent-session/acpmux/Composer.tsx#Composer"],
  load: async () => {
    const { Composer } = await import("./Composer");
    return function GalleryComposerTrust({ state }: Props) {
      const handle = useRef<ComposerHandle>(null);
      const [sent, setSent] = useState("");
      useLayoutEffect(() => {
        handle.current?.restore("Use the cache", []);
        setSent("");
      }, [state]);
      const snapshot = noChat([], {
        sessionId: "gallery-trust-send",
        summary: { sessionId: "gallery-trust-send", harness: "claude", cwd: "/demo/app", turnCount: 1 },
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
              setSent(text);
              return true;
            }}
            onStop={() => {}}
            onProject={() => {}}
            onNewChat={() => {}}
            localName="studio"
            projectChoices={[{ cwd: "/demo/app", label: "app" }]}
            blocked={state === "ask" ? { reason: "trust.answerFirst" } : {}}
            blockSend={state === "folder"}
          />
          {sent && <output aria-label="Sent prompt">{sent}</output>}
        </div>
      );
    };
  },
  variants: {
    reading: { props: { state: "reading" }, note: "Send remains usable while the trust read is in flight." },
    ask: { props: { state: "ask" }, note: "A concrete trust question keeps the draft until answered." },
    folder: { props: { state: "folder" }, note: "The New Tab folder choice remains a separate hard stop." },
  },
});
