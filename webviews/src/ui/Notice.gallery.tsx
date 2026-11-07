// l10n-allow-file: gallery fixtures, not shipped UI.
// The notice system (leo-workspace design/notifications.md): every kind, in three looks. Light and
// dark are the gallery's theme axis and compact or comfortable its density axis. Chosen and live:
// `card` (Claude's proposal card and Codex's limit card: a mark, a title, a plain line, buttons at
// the trailing edge, the checkmark at the leading edge). `line` (Sonner's one-row toast) and
// `header` (Codex's card with a tinted title strip) stay here for comparison.
import { useMemo, useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Notice, type NoticeKind } from "./Notice";
import { createNoticeQueue, NoticeStack } from "./NoticeStack";

type Look = "card" | "line" | "header";
type Props = { look: Look; only?: NoticeKind | "stack" };

const noop = () => undefined;

function Kinds({ look, only }: Props) {
  const [askFirst, setAskFirst] = useState(false);
  const [answer, setAnswer] = useState("");
  const show = (kind: NoticeKind) => !only || only === kind;
  return (
    <div className="ui-notice-gallery" data-look={look}>
      {show("toast") && (
        <Notice
          kind="toast"
          message="Moved this chat to Cloud machine dev."
          actions={[{ id: "undo", label: "Undo", onSelect: () => setAnswer("undo") }]}
          onDismiss={noop}
          dismissLabel="Dismiss"
        />
      )}
      {show("ask") && (
        <Notice
          kind="ask"
          title="Start claude on a Cloud machine?"
          message="The agent asks to run this task on Cloud machine dev, copying demo-app there."
          actions={[
            { id: "notNow", label: "Not now", onSelect: () => setAnswer("notNow") },
            { id: "start", label: "Start", primary: true, onSelect: () => setAnswer("start") },
          ]}
          check={{ label: "Ask me first", checked: askFirst, onCheckedChange: setAskFirst }}
        />
      )}
      {show("ask") && (
        <Notice
          kind="toast"
          message="Starting claude on Cloud machine dev."
          check={{
            label: "Ask me first",
            hint: "Agents start Cloud sessions without asking. Check to be asked each time.",
            checked: askFirst,
            onCheckedChange: setAskFirst,
          }}
        />
      )}
      {show("warning") && (
        <Notice
          kind="warning"
          title="All your Cloud machines are busy"
          message="Your plan's running machines are all in use. Pause one to make room, upgrade for more, or run this on your Mac."
          actions={[
            { id: "runHere", label: "Run on This Mac", onSelect: noop },
            { id: "upgrade", label: "Upgrade", primary: true, onSelect: noop },
          ]}
          onDismiss={noop}
          dismissLabel="Dismiss"
        />
      )}
      {show("error") && (
        <Notice
          kind="error"
          title="Couldn't start the session"
          message="Lost the connection to Cloud machine dev during the start."
          retry={{ label: "Retry", onRetry: () => setAnswer("retry") }}
          actions={[{ id: "details", label: "Details", onSelect: noop }]}
          onDismiss={noop}
          dismissLabel="Dismiss"
        />
      )}
      <output className="ui-notice-gallery-receipt" data-testid="notice-receipt">
        {[answer, askFirst ? "ask-first" : ""].filter(Boolean).join(" ")}
      </output>
    </div>
  );
}

function Stack({ look }: Props) {
  const queue = useMemo(() => {
    const made = createNoticeQueue();
    made.show({ id: "a", message: "Archived 3 chats.", actions: [{ id: "undo", label: "Undo", onSelect: noop }] });
    made.show({ id: "b", kind: "error", message: "Couldn't update cmux-tui on dev.", duration: 0 });
    made.show({ id: "c", message: "Copied the link.", duration: 0 });
    return made;
  }, []);
  return (
    <div className="ui-notice-gallery ui-notice-gallery-stage" data-look={look}>
      <NoticeStack queue={queue} dismissLabel="Dismiss" />
    </div>
  );
}

function NoticeGallery(props: Props) {
  return props.only === "stack" ? <Stack {...props} /> : <Kinds {...props} />;
}

const checkAskFirst: Play = async (ctx) => {
  await ctx.click({ role: "checkbox" });
  await ctx.waitFor(() => ctx.find({ testId: "notice-receipt" }).textContent === "ask-first");
};

const retryLeads: Play = async (ctx) => {
  await ctx.press("Tab");
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.find({ testId: "notice-receipt" }).textContent === "retry");
};

export default componentEntry<Props>({
  id: "ui.notice",
  title: "Notice",
  area: "UI primitives",
  height: 560,
  covers: ["ui/Notice.tsx", "ui/NoticeStack.tsx#NoticeStack"],
  load: async () => NoticeGallery,
  styles: () => Promise.all([import("./ui.css"), import("./Notice.gallery.css")]),
  variants: {
    card: { props: { look: "card" }, note: "Shipped: mark, title, line, trailing buttons, leading checkmark." },
    line: { props: { look: "line" }, note: "Option: Sonner's one-row toast; buttons beside the text." },
    header: { props: { look: "header" }, note: "Option: Codex's limit card with a title strip." },
    stack: { props: { look: "card", only: "stack" }, note: "Three toasts over a pane: newest at the bottom." },
    "ask-check": { props: { look: "card", only: "ask" }, play: checkAskFirst },
    "error-retry-first": { props: { look: "card", only: "error" }, play: retryLeads },
  },
});
