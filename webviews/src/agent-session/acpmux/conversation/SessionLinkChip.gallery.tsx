// l10n-allow-file: deterministic, public-safe fixture for the session link chip's colours.
// Leo, 2026-11-01: "dont do blue by default, theme it". The chip that opens another chat (a received
// message's sender, a sent message's recipient, a started chat's name in a reply), drawn by its real
// components. Pick a theme in the gallery's theme menu (Catppuccin Mocha, say): the shipped chip
// takes that theme's text colour, never a fixed blue. The other variants are compared looks.
// design/chat-transcript.md "Session link chip".
import { useLayoutEffect } from "react";
import { componentEntry } from "../../../gallery/format";
import { tool } from "../../../gallery/fixtures/acpmux";
import { StartedSessionChip } from "../started/StartedSessionCard";
import { SubsessionContext, SubsessionStore } from "../subagents/subsessions";
import type { AcpmuxSessionEntry } from "../sessionList";
import { acpmuxSendCall } from "./acpmuxSends";
import { IncomingMessageLine } from "./IncomingMessageCard";
import { AcpmuxSendLine } from "./SentMessageLine";

type Look = "theme" | "accent" | "quiet" | "link-blue";
type Props = { look: Look };

const entry = (fields: Partial<AcpmuxSessionEntry> & { sessionId: string }) =>
  ({ displayTitle: fields.name ?? "", pendingPermissions: 0, ...fields }) as AcpmuxSessionEntry;
const store = new SubsessionStore();
store.set([
  entry({ sessionId: "chip-lane", name: "lane-host-2/acpmux-owner", peer: "lane-host-2", harness: "claude" }),
  entry({ sessionId: "chip-verify", name: "ui-verify", hostKind: "local", harness: "claude" }),
]);
const shellSend = tool("acpmux send", "execute", "completed", {
  id: "chip-shell-send",
  command: "acpmux send --no-wait lane-host-2/acpmux-owner 'Make sure the daemon links resolve on every host.'",
  output: "queued",
});

function SessionLinkChipGallery({ look }: Props) {
  useLayoutEffect(() => {
    const root = document.documentElement;
    if (look === "theme") delete root.dataset.sessionChipLook;
    else root.dataset.sessionChipLook = look;
    return () => void delete root.dataset.sessionChipLook;
  }, [look]);
  const send = acpmuxSendCall(shellSend.tool!)!;
  return (
    <SubsessionContext.Provider value={{ store, open: () => undefined }}>
      <main className="session-link-chip-gallery" data-session-link-chip>
        <section className="acpmux-row session-link-chip-gallery__row">
          <div className="cv-tools">
            <AcpmuxSendLine tool={shellSend.tool!} send={send} />
          </div>
        </section>
        <section className="acpmux-row session-link-chip-gallery__row">
          <IncomingMessageLine
            id="chip-gallery-received"
            message={{
              name: "lane-host-2/acpmux-owner",
              text: "The daemon links resolve on every host now.",
              raw: "[lane-host-2/acpmux-owner] The daemon links resolve on every host now.",
            }}
            onOpen={() => undefined}
          />
        </section>
        <section className="acpmux-row session-link-chip-gallery__row">
          <IncomingMessageLine
            id="chip-gallery-plain"
            message={{ name: "gone-lane", text: "Done here.", raw: "[gone-lane] Done here." }}
            onOpen={() => undefined}
          />
        </section>
        <p className="cv-md session-link-chip-gallery__row">
          Started{" "}
          <StartedSessionChip
            mention={{ sessionId: "chip-verify", text: "ui-verify", title: "ui-verify", state: "running" }}
            text="ui-verify"
            onOpen={() => undefined}
          />{" "}
          to check the build, and{" "}
          <a href="https://example.com/docs" onClick={(event) => event.preventDefault()}>
            a prose link
          </a>{" "}
          stays blue.
        </p>
      </main>
    </SubsessionContext.Provider>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.session-link-chip",
  title: "Session link chip",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  anchors: [{ selector: "[data-session-link-chip]" }],
  covers: [
    "agent-session/acpmux/conversation/AgentTag.tsx",
    "agent-session/acpmux/started/StartedSessionCard.tsx#StartedSessionChip",
  ],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("../started/startedSessions.css"),
      import("./SessionLinkChip.gallery.css"),
    ]),
  load: async () => SessionLinkChipGallery,
  variants: {
    theme: {
      props: { look: "theme" },
      note: "Shipped. The theme's text on a 9% wash of it with an 18% hairline ring and the open cue; under the pointer the wash goes to 16% and the ring to 30%. The plain sender below (no chat to open) keeps the grey tag with no cue.",
    },
    accent: {
      props: { look: "accent" },
      note: "Compared: the theme's accent token. Follows the theme, but a theme whose accent is its blue gives back the blue chip.",
    },
    quiet: {
      props: { look: "quiet" },
      note: "Compared: muted text with no wash at rest, the wash only under the pointer. Calmest, but at rest it reads as the row's own words, which is what the chip was made to fix.",
    },
    "link-blue": {
      props: { look: "link-blue" },
      note: "Replaced (cmux#30051): the link blue on a 13% tint of it, the same in every theme.",
    },
  },
});
