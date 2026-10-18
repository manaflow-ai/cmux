// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AcpmuxAgentMessage } from "../model";
import { ReceivedGroup, ReceivedMessage } from "./ReceivedMessage";

type Props = { messages: AcpmuxAgentMessage[]; open?: string[] };

const message = (n: number, title: string, body: string, linked = true): AcpmuxAgentMessage => ({
  msgId: `m${n}`,
  title,
  ...(linked ? { sessionId: `lane-${n}` } : {}),
  body,
});

const one = [
  message(
    1,
    "Fix the uploader retry",
    "The retry now backs off 1s, 2s, 4s and stops after five tries. Tests are green on the branch; PR is up as #412.",
  ),
];
const several = [
  one[0]!,
  message(2, "Release checklist", "Notes are drafted. I still need the version number from you before I tag."),
  message(3, "cmux agent message", "Rebased on main; no conflicts.", false),
];

/// The lines as the thread draws them: one alone, or several folded under "Received N messages",
/// each opening to its words.
function GalleryReceived({ messages, open = [] }: Props) {
  const [shown, setShown] = useState(new Set(open));
  const toggle = (id: string) =>
    setShown((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  const lines = messages.map((entry) => (
    <ReceivedMessage
      key={entry.msgId}
      message={entry}
      open={shown.has(entry.msgId)}
      onToggle={() => toggle(entry.msgId)}
      onOpen={() => undefined}
    />
  ));
  return (
    <div className="acpmux-shell">
      <div data-received-fixture style={{ flex: 1, minWidth: 0, padding: 12 }}>
        {messages.length > 1 ? (
          <>
            <ReceivedGroup
              row={{ id: "group", kind: "receivedGroup", version: 1, at: 0, count: messages.length }}
              open={shown.has("group")}
              onToggle={() => toggle("group")}
            />
            {shown.has("group") && lines}
          </>
        ) : (
          lines
        )}
      </div>
    </div>
  );
}

const openFirst: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Show message" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-received__body"));
};

const openGroup: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Received 3 messages" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-received__chevron").length === 3);
};

export default componentEntry<Props>({
  id: "agent-pane.received-messages",
  title: "Messages from other sessions",
  area: "Agent pane",
  pane: true,
  height: 200,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: "[data-received-fixture]" }],
  covers: [
    "agent-session/acpmux/conversation/ReceivedMessage.tsx#ReceivedMessage",
    "agent-session/acpmux/conversation/ReceivedMessage.tsx#ReceivedGroup",
  ],
  styles: () => import("../styles.css"),
  load: async () => GalleryReceived,
  variants: {
    one: {
      note: "Another session's message: one muted line naming its sender, a link to that chat.",
      props: { messages: one },
      height: 60,
    },
    "one-open": {
      note: "Play: the chevron opens the sender's own words under the line, in muted body type.",
      props: { messages: one },
      height: 110,
      play: openFirst,
    },
    several: {
      note: "Three messages in a row fold into one line.",
      props: { messages: several },
      height: 60,
    },
    "several-open": {
      note: "Play: the folded line opens to a line per message; a sender that is not a chat is plain text.",
      props: { messages: several, open: ["m2"] },
      height: 180,
      play: openGroup,
    },
  },
});
