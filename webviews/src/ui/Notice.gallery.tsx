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
// The toast glass's veil (Leo 2026-11-07: "these toasts are still coloured unthemed"). Chosen and
// live: `theme`, the theme's surface at the toast's veil opacity under the neutral rim. `gray` is
// the neutral veil it replaced; `popover` the popovers' denser theme tint. Compare them under a
// hued theme (the gallery's theme axis).
type Tint = "theme" | "gray" | "popover";
// The toast's glass (glass-raycast-parity.md "Web popups"; design-system-decisions B1 `floating`; the
// toast-glass experiment, ui/toastGlass.experiment.ts). Shipped: `page`, the page's floating material.
// `host`, behind `experiments.toastGlass` (off by default): the App's own toast glass under the page where
// the App draws it, the native toasts' material. A browser gallery has no App, so the two look alike
// here: the App's capture shows them.
type Glass = "host" | "page";
type Props = { look: Look; only?: NoticeKind | "stack"; tint?: Tint; glass?: Glass; busy?: boolean };

const noop = () => undefined;
// Transcript-like text under the stack: the glass has to keep a toast legible over busy content.
const BUSY_TEXT =
  "Read 14 files in webviews/src/ui. The stack draws each card through the toast.enter slot, so a theme can " +
  "change how a toast arrives without touching the card. Ran the gallery capture for ui.notice in light and " +
  "dark; every variant matched its last approved image except the two toasts the change is about. ".repeat(4);

function Kinds({ look, only, tint = "theme" }: Props) {
  const [askFirst, setAskFirst] = useState(false);
  const [answer, setAnswer] = useState("");
  const show = (kind: NoticeKind) => !only || only === kind;
  return (
    <div className="ui-notice-gallery" data-look={look} data-tint={tint}>
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

function Stack({ look, tint = "theme", glass = "page", busy = false }: Props) {
  const queue = useMemo(() => {
    const made = createNoticeQueue();
    made.show({ id: "a", message: "Archived 3 chats.", actions: [{ id: "undo", label: "Undo", onSelect: noop }] });
    made.show({ id: "b", kind: "error", message: "Couldn't update cmux-tui on dev.", duration: 0 });
    made.show({ id: "c", message: "Copied the link.", duration: 0 });
    return made;
  }, []);
  return (
    <div
      className="ui-notice-gallery ui-notice-gallery-stage"
      data-look={look}
      data-tint={tint}
      data-busy={busy || undefined}
    >
      {busy && (
        <p className="ui-notice-gallery-busy" aria-hidden="true">
          {BUSY_TEXT}
        </p>
      )}
      <NoticeStack queue={queue} dismissLabel="Dismiss" hostGlass={glass === "host"} />
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
    "tint-theme": {
      props: { look: "card", only: "stack", tint: "theme" },
      note: "Shipped: the theme's surface at the toast veil's opacity, the neutral rim.",
    },
    "tint-gray": {
      props: { look: "card", only: "stack", tint: "gray" },
      note: "Before: the neutral gray veil in every theme.",
    },
    "tint-popover": {
      props: { look: "card", only: "stack", tint: "popover" },
      note: "Option: the popovers' theme tint (--ds-glass-popover-tint).",
    },
    "glass-page": {
      props: { look: "card", only: "stack", glass: "page" },
      note: "Shipped (the default): the page's floating material, today's toast.",
    },
    "glass-host": {
      props: { look: "card", only: "stack", glass: "host" },
      note: "experiments.toastGlass (off by default): each toast on the App's own toast glass under the page (data-host-glass, role toast).",
    },
    "glass-host-busy": {
      props: { look: "card", only: "stack", glass: "host", busy: true },
      note: "experiments.toastGlass, over busy transcript text: the glass keeps the toast legible.",
    },
    "ask-check": { props: { look: "card", only: "ask" }, play: checkAskFirst },
    "error-retry-first": { props: { look: "card", only: "error" }, play: retryLeads },
  },
});
