// l10n-allow-file: gallery fixtures, not shipped UI.
// The notice system (leo-workspace design/notifications.md): every kind, in three looks. Light and
// dark are the gallery's theme axis and compact or comfortable its density axis. Chosen and live:
// `card` (Claude's proposal card and Codex's limit card: a mark, a title, a plain line, buttons at
// the trailing edge, the checkmark at the leading edge). `line` (Sonner's one-row toast) and
// `header` (Codex's card with a tinted title strip) stay here for comparison.
import { useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import looks from "virtual:cmux-gallery/looks";
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
type Props = { look: Look; only?: NoticeKind | "stack" | "corners"; tint?: Tint };

const noop = () => undefined;

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

function Stack({ look, tint = "theme" }: Props) {
  const queue = useMemo(() => {
    const made = createNoticeQueue();
    made.show({ id: "a", message: "Archived 3 chats.", actions: [{ id: "undo", label: "Undo", onSelect: noop }] });
    made.show({ id: "b", kind: "error", message: "Couldn't update cmux-tui on dev.", duration: 0 });
    made.show({ id: "c", message: "Copied the link.", duration: 0 });
    return made;
  }, []);
  return (
    <div className="ui-notice-gallery ui-notice-gallery-stage" data-look={look} data-tint={tint}>
      <NoticeStack queue={queue} dismissLabel="Dismiss" />
    </div>
  );
}

// The toast's corner, three candidates side by side (Leo 2026-11-22: "the toast is this awkward pill
// glass. im not sure if it should be that rounded"): 16, the uncapped concentric corner it drew
// before; 9, the toast role's own radius, shipped; 12, between. Each column only sets the role
// variable --surface-toast-radius (Notice.gallery.css), so the corner is one role value, and prints
// the toast's measured corner and height.
const CORNERS = [
  { id: "16", label: "16: before, the concentric 8 + 8" },
  { id: "9", label: "9: the toast role, shipped" },
  { id: "12", label: "12: between" },
] as const;

function Measured({ children, label }: { children: ReactNode; label: string }) {
  const box = useRef<HTMLDivElement>(null);
  const [sizes, setSizes] = useState<string[]>([]);
  useLayoutEffect(() => {
    const element = box.current;
    if (!element) return undefined;
    const measure = () =>
      setSizes(
        [...element.querySelectorAll<HTMLElement>(".ui-notice")].map((notice) => {
          const radius = getComputedStyle(notice).borderTopLeftRadius;
          return `corner ${Number.parseFloat(radius)}, height ${Math.round(notice.getBoundingClientRect().height)}`;
        }),
      );
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  return (
    <figure className="ui-notice-corner-cell">
      <figcaption className="ui-notice-corner-label">{label}</figcaption>
      <div ref={box} className="ui-notice-corner-toasts">
        {children}
      </div>
      <output className="ui-notice-corner-sizes">
        {sizes.map((size, index) => (
          <span key={index}>{size}</span>
        ))}
      </output>
    </figure>
  );
}

function Corners({ tint = "theme" }: Props) {
  return (
    <div className="ui-notice-gallery ui-notice-corners" data-look="card" data-tint={tint}>
      {CORNERS.map((corner) => (
        <div key={corner.id} className="ui-notice-corner" data-radius={corner.id}>
          <Measured label={corner.label}>
            <Notice
              kind="toast"
              placement="stack"
              message="Moved this chat to Cloud machine dev."
              actions={[{ id: "undo", label: "Undo", onSelect: noop }]}
              onDismiss={noop}
              dismissLabel="Dismiss"
            />
            <Notice
              kind="toast"
              placement="stack"
              title="Moved this chat to Cloud machine dev"
              message="It keeps running there when this Mac sleeps."
              onDismiss={noop}
              dismissLabel="Dismiss"
            />
          </Measured>
        </div>
      ))}
    </div>
  );
}

function NoticeGallery(props: Props) {
  if (props.only === "stack") return <Stack {...props} />;
  if (props.only === "corners") return <Corners {...props} />;
  return <Kinds {...props} />;
}

// A look from examples/looks drawn over the toast (its theme file per scheme), absent when this
// checkout lacks its files.
const material = looks.looks.find((look) => look.id === "material-addon");

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
    corners: {
      props: { look: "card", only: "corners" },
      note: "The toast's corner at 16 (before), 9 (the toast role, shipped) and 12: only --surface-toast-radius differs.",
    },
    ...(material && {
      "corners-material": {
        props: { look: "card", only: "corners" },
        look: material,
        note: "The three corners under the Material look (examples/looks/material).",
      },
      "stack-material": {
        props: { look: "card", only: "stack" },
        look: material,
        note: "Three toasts over a pane under the Material look (examples/looks/material).",
      },
    }),
    "ask-check": { props: { look: "card", only: "ask" }, play: checkAskFirst },
    "error-retry-first": { props: { look: "card", only: "error" }, play: retryLeads },
  },
});
