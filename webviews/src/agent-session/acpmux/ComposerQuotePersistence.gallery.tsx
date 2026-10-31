// l10n-allow-file: public-safe persistence fixture controls and sample quote.
import { componentEntry } from "../../gallery/format";
import { noChat } from "../../gallery/fixtures/acpmux";
import type { ComposerHandle } from "./Composer";

export default componentEntry({
  id: "agent-pane.composer-quote-persistence",
  title: "Quoted draft survives closing the composer",
  area: "Agent pane",
  pane: true,
  widths: { narrow: 400, normal: 760, wide: 1040 },
  height: 650,
  covers: ["agent-session/acpmux/MarkdownField.tsx", "agent-session/acpmux/Composer.tsx"],
  styles: async () => {
    await import("./styles.css");
    await import("./markdownField.css");
    await import("./composerLook.css");
  },
  load: async () => {
    const { useEffect, useRef, useState } = await import("react");
    const { Composer } = await import("./Composer");
    const { notifyDraftActionsChanged } = await import("./composerDraft");
    const previous = window.cmuxAcpmuxActions;
    let durable = "";
    // Stand in only for the daemon's draft storage. The Composer owns serialization, settling,
    // teardown, remount and sending, exactly as it does under the agent pane.
    window.cmuxAcpmuxActions = {
      "chat.readDraft": async () => ({ draft: durable }),
      "chat.writeDraft": async ({ text }) => {
        durable = String(text);
      },
    };
    notifyDraftActionsChanged();
    const sessionId = "gallery-quote-persistence";
    const snapshot = noChat([], {
      sessionId,
      summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 0 },
    });
    const Chips = () => null;
    return function QuotePersistence() {
      const handle = useRef<ComposerHandle>(null);
      const [open, setOpen] = useState(true);
      const [sent, setSent] = useState<string>();
      useEffect(
        () => () => {
          window.cmuxAcpmuxActions = previous;
          notifyDraftActionsChanged();
        },
        [],
      );
      return (
        <div>
          <button onClick={() => handle.current?.quoteReply("> Keep this quote separate.")}>Quote selection</button>
          <button
            onClick={async () => {
              await handle.current?.settleDraft();
              setOpen(false);
            }}
          >
            Save and close
          </button>
          <button onClick={() => setOpen(true)}>Reopen</button>
          {open && (
            <Composer
              handle={handle}
              snapshot={snapshot}
              sessionId={sessionId}
              chips={Chips}
              onStop={() => {}}
              onSend={(markdown) => {
                setSent(markdown);
                return true;
              }}
            />
          )}
          <output data-sent-markdown="">{sent}</output>
        </div>
      );
    };
  },
  variants: { ready: { props: {} } },
});
