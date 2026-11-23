// l10n-allow-file: gallery transcript fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { intl } from "../../ui/intl";
import { createStrings } from "../shared/i18n";
import { TranscriptRowView } from "./transcript/TranscriptRows";
import { MessageRow } from "./MessageRow";
import { RunSteps } from "./RunSteps";
import type { HomeMessage, HomeRun, HomeRunStep } from "./types";
import table from "./generated/strings.json";

type Surface = "channel" | "messages" | "run";
const at = Date.UTC(2026, 10, 19, 10, 30);
const text = "Finished at 10:20 UTC. Read [the reference](https://example.com/reference).";
const message: HomeMessage = {
  id: "hover-message",
  conversation: "hover-chat",
  seq: 1,
  author: "agent",
  createdAt: at,
  retracted: false,
  reactions: [],
  parts: [{ type: "text", text, mentions: [] }],
};
const run: HomeRun = {
  id: "hover-run",
  conversation: "hover-chat",
  author: "agent",
  status: "done",
  startedAt: at,
  updatedAt: at,
  rev: 1,
  stepCount: 1,
  answers: [],
};
const step: HomeRunStep = {
  id: "hover-step",
  seq: 1,
  at,
  rev: 1,
  kind: "talk",
  text: "Finished at 10:20 UTC.",
  attachments: [],
  links: [{ label: "Reference", url: "https://example.com/reference" }],
};

function TranscriptHover({ surface }: { surface: Surface }) {
  const [strings] = useState(() => createStrings(table, ["en"]));
  return (
    <main style={{ padding: "calc(var(--ds-space-48) * 2) var(--ds-space-5)", maxWidth: 640 }}>
      {surface === "run" ? (
        <RunSteps run={run} steps={[step]} agentNames={new Map()} />
      ) : surface === "channel" ? (
        <MessageRow
          message={message}
          head
          people={new Map()}
          strings={strings}
          timeFormat={intl.DateTimeFormat("en")}
          editing={false}
          onReact={() => {}}
        />
      ) : (
        <TranscriptRowView
          row={{
            kind: "bubble",
            key: "hover-row",
            gap: 0,
            message,
            parts: message.parts,
            partIndex: 0,
            outgoing: false,
            tail: true,
            indent: false,
            reactions: [],
            markdown: true,
          }}
          me="reader"
          strings={strings}
          now={at}
          people={new Map()}
          actions={{}}
        />
      )}
    </main>
  );
}

const hover =
  (link = false): Play =>
  async (ctx) => {
    await ctx.hover({ selector: link ? ".lg-run-links a" : "time.cv-time-hover" });
    await ctx.waitFor(() => {
      const popup = ctx.document.querySelector(link ? ".cv-link-preview" : ".ui-tooltip");
      return !!popup && ctx.document.defaultView?.getComputedStyle(popup).opacity === "1";
    });
  };

export default componentEntry<{ surface: Surface }>({
  id: "home-channels.transcript-hover",
  title: "Transcript timestamp and link previews",
  area: "Home",
  pane: true,
  height: 360,
  widths: { narrow: 360, normal: 640 },
  covers: [
    "pages/home-channels/MessageRow.tsx",
    "pages/home-channels/RunSteps.tsx",
    "pages/home-channels/transcript/TranscriptRows.tsx",
    "agent-session/acpmux/chips/LinkChips.tsx",
  ],
  styles: () =>
    Promise.all([
      import("../../agent-session/acpmux/conversation/conversation.css"),
      import("./styles.css"),
      import("./ledger.css"),
      import("./transcript/transcript.css"),
    ]),
  load: async () => TranscriptHover,
  variants: {
    channel: {
      props: { surface: "channel" },
      note: "A channel message supplies its date to the time tooltip.",
      play: hover(),
    },
    messages: {
      props: { surface: "messages" },
      note: "A message bubble uses the same timestamp tooltip.",
      play: hover(),
    },
    run: {
      props: { surface: "run" },
      note: "A run step supplies its own date to the time tooltip.",
      play: hover(),
    },
    "run-link": {
      props: { surface: "run" },
      note: "A run-step link opens the same preview as a Markdown link.",
      play: hover(true),
    },
  },
});
