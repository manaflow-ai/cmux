// l10n-allow-file: gallery fixtures (sample workspace names, release lines, labels), not shipped UI.
// Prototype, nothing shipped changes: where What's New and the update button go once the sidebar's
// card stops holding them (Leo 2026-11-24: "the annoyingly huge pill on the sidebar, which is actually
// prime real estate, which currently only tells you \"durr ok you updated\"" and "we suddenly have freedom
// to solve a relatively simpler problem of placing a smaller button"). Owner of the change: Lucas.
//
// Each variant draws one window twice, at rest and in the state, so a move shows at a glance: the
// sidebar's rows, the footer row and the composer must sit on the same pixels in both copies.
//   now-*:     today. The card over the footer row takes rows from the list; `now-updated` mounts the
//              real UpdatedCard, `now-ready` stands in for the native Update Ready card.
//   news-*:    after an update, What's New lives on the New Tab page: a text chip in the page's
//              top-right corner (`corner-chip`, Claude Code's place for it), a glyph alone there
//              (`corner-dot`), or one line in a reserved row under the composer (`composer-line`).
//   button-*:  before an update, the footer's existing update slot (left of Search) carries the whole
//              flow: a glyph alone (`icon`), a short label that grows into the free room at its left
//              (`label`), or the glyph with a small Later control above it on hover (`opt-out`).
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { ComponentVariant } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import type { UpdateHighlights } from "./updateHighlights";
import { UpdatedCard } from "./UpdateSurfaces";

type News = "card" | "corner-chip" | "corner-dot" | "composer-line";
type ButtonLook = "card" | "icon" | "label" | "opt-out";
type State = "available" | "downloading" | "ready" | "updated";
type Props = { news: News; button: ButtonLook; state: State; open?: boolean; read?: boolean };

const data: UpdateHighlights = {
  version: "1.0.0-nightly.4431815985601",
  build: "4431815985601",
  fromVersion: "1.0.0-nightly.4430000000001",
  fromBuild: "4430000000001",
  date: "2026-11-24",
  source: "whatsNew",
  language: "en",
  items: [
    { id: "undo-close", title: "Undo a tab close from a toast", summary: null, category: "new" },
    { id: "restart", title: "Restart to Update keeps every window", summary: null, category: "improved" },
    { id: "scroll", title: "Lock horizontal scroll", summary: null, category: "fixed" },
  ],
  moreCount: 4,
  changelog: { from: "1.0.0-nightly.4430000000001", to: "1.0.0-nightly.4431815985601" },
};

const KIND = { new: "New", improved: "Improved", fixed: "Fixed" } as const;
// More rows than the sidebar holds, as a working sidebar has: what a card takes shows as rows gone.
const ROWS = [
  "workspace-404",
  "claude-sr2-coord",
  "chat-export-anywhere",
  "update-button",
  "docs-site",
  "perf-cron",
  "gallery-shift",
  "ios-parity",
  "settings-search",
  "theme-slots",
  "cloud-resume",
  "release-notes",
  "sidebar-footer",
];
const noop = () => undefined;

function Glyph({ name }: { name: "down" | "restart" | "spark" | "close" }) {
  const path = {
    down: "M8 4.5v6m0 0L5.5 8m2.5 2.5L10.5 8",
    restart: "M11.2 6.2A3.6 3.6 0 1 0 11.6 9M11.4 3.8v2.6H8.8",
    spark: "M8 3.2l1.1 3.1 3.1 1.1-3.1 1.1L8 11.6 6.9 8.5 3.8 7.4l3.1-1.1z",
    close: "M5.5 5.5l5 5m0-5l-5 5",
  }[name];
  return (
    <svg className="ufp-glyph" viewBox="0 0 16 16" aria-hidden="true">
      <path d={path} fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

/** The footer's update slot, left of Search: empty at rest, the button in a state. */
function UpdateSlot({ look, state }: { look: ButtonLook; state: State | null }) {
  if (look === "card" || state === null || state === "updated") return <span className="ufp-slot" />;
  const label = state === "ready" ? "Restart" : state === "downloading" ? "42%" : "Update";
  return (
    <span className="ufp-slot" data-state={state}>
      {look === "opt-out" && state !== "downloading" && (
        <span className="ufp-later">
          <Glyph name="close" />
          Later
        </span>
      )}
      <span className="ufp-update" data-look={look} data-state={state}>
        {state === "downloading" ? (
          <span className="ufp-ring" />
        ) : (
          <Glyph name={state === "ready" ? "restart" : "down"} />
        )}
        {look === "label" && <span className="ufp-update-label">{label}</span>}
      </span>
    </span>
  );
}

/** Today's native Update Ready card (SidebarUpdateCardView), drawn from the tokens. */
function ReadyCardStandIn() {
  return (
    <div className="ufp-card">
      <span className="ufp-card-title">Update Ready</span>
      <span className="ufp-card-line">Nightly 4431815985601</span>
      <span className="ufp-card-button">Restart to Update</span>
    </div>
  );
}

function NewsPopover() {
  return (
    <div className="ufp-popover">
      <span className="ufp-popover-title">What’s new in Nightly</span>
      {data.items.map((item) => (
        <span key={item.id} className="ufp-popover-row">
          <span className="ufp-kind">{KIND[item.category]}</span>
          {item.title}
        </span>
      ))}
      <span className="ufp-popover-more">See all {data.items.length + data.moreCount} changes</span>
    </div>
  );
}

function Window({
  news,
  button,
  state,
  open,
  read,
}: {
  news: News;
  button: ButtonLook;
  state: State | null;
  open: boolean;
  read: boolean;
}) {
  const [strings] = useState(() => createStrings(table));
  const updated = state === "updated";
  return (
    <div className="ufp-window">
      <div className="ufp-sidebar">
        <div className="ufp-list">
          {ROWS.map((row) => (
            <span key={row} className="ufp-list-row">
              {row}
            </span>
          ))}
        </div>
        {news === "card" && updated && (
          <div className="ufp-card-host">
            <UpdatedCard data={data} strings={strings} actions={{ openChangelog: noop, dismiss: noop }} />
          </div>
        )}
        {button === "card" && state === "ready" && <ReadyCardStandIn />}
        <div className="ufp-footer">
          <span className="ufp-avatar">L</span>
          <span className="ufp-strip">
            <span className="ufp-space" data-active="true" />
            <span className="ufp-space" />
            <span className="ufp-plus">+</span>
          </span>
          <UpdateSlot look={button} state={state} />
          <span className="ufp-search" />
        </div>
      </div>
      <div className="ufp-pane">
        {updated && news === "corner-chip" && (
          <span className="ufp-corner" data-look="chip" data-read={read || undefined}>
            {!read && <span className="ufp-unread" />}
            What’s new
          </span>
        )}
        {updated && news === "corner-dot" && (
          <span className="ufp-corner" data-look="dot">
            <Glyph name="spark" />
            {!read && <span className="ufp-unread" />}
          </span>
        )}
        {updated && open && news !== "card" && news !== "composer-line" && <NewsPopover />}
        <div className="ufp-composer">
          <span className="ufp-placeholder">Ask anything</span>
        </div>
        {/* The row under the composer is always there, so a line arriving in it moves nothing. */}
        <div className="ufp-under">
          {updated && news === "composer-line" && (
            <span className="ufp-line">
              <span className="ufp-kind">New</span>
              {data.items[0]!.title}
              <span className="ufp-line-more">and {data.items.length + data.moreCount - 1} more</span>
            </span>
          )}
        </div>
      </div>
    </div>
  );
}

function UpdateFootprintGallery({ news, button, state, open = false, read = false }: Props) {
  const caption = {
    available: "An update is available",
    downloading: "Downloading",
    ready: "Ready to restart",
    updated: "Just updated",
  }[state];
  return (
    <div className="ufp-gallery">
      <span className="ufp-caption">At rest</span>
      <Window news={news} button={button} state={null} open={false} read={false} />
      <span className="ufp-caption">{caption}</span>
      <Window news={news} button={button} state={state} open={open} read={read} />
    </div>
  );
}

const NEWS: Record<Exclude<News, "card">, string> = {
  "corner-chip":
    "What’s New as a text chip in the New Tab page’s top-right corner, over the page’s own padding: nothing reflows, the sidebar keeps every row.",
  "corner-dot":
    "The same corner, a glyph with an unread dot and no words: the least room, but it does not say what it is until hovered.",
  "composer-line":
    "One line in a row under the composer that is always reserved: it names the first change, where the eye already is.",
};
const BUTTONS: Record<Exclude<ButtonLook, "card">, string> = {
  icon: "The footer’s existing update slot, a glyph alone: an arrow, a progress ring, then an accent restart glyph.",
  label:
    "The same slot with a short word (Update, 42%, Restart) growing leftward. Round 1 finding: at a narrow sidebar the word runs into the centered spaces strip, so this look needs a fallback to the glyph and loses to it.",
  "opt-out": "The glyph, with a small Later control above it on hover: the opt-out costs no room at rest.",
};
const STATES: Record<Exclude<State, "updated">, string> = {
  available: "An update is available and waits for a click.",
  downloading: "The update downloads.",
  ready: "The update is staged: one click restarts into it.",
};

const variants: Record<string, ComponentVariant<Props>> = {
  "now-updated": {
    note: "Today, after an update: the real Updated card over the footer row. It takes rows from the list to say the app updated.",
    props: { news: "card", button: "card", state: "updated" },
  },
  "now-ready": {
    note: "Today, an update staged: the native Update Ready card (a stand-in here) with its wide Restart to Update button.",
    props: { news: "card", button: "card", state: "ready" },
  },
};
for (const [news, note] of Object.entries(NEWS) as [Exclude<News, "card">, string][]) {
  variants[`news-${news}`] = { note, props: { news, button: "icon", state: "updated" } };
  if (news !== "composer-line")
    variants[`news-${news}-open`] = {
      note: `${note} Open, on a click only: the changes in a popover hung from the corner. It may stand over the composer's end, so it closes on the first key typed.`,
      props: { news, button: "icon", state: "updated", open: true },
    };
}
variants["news-corner-chip-read"] = {
  note: "The corner chip once its changes were opened: the dot is gone and the words go quiet, until the next update. The corner never holds anything else, so it can also leave entirely.",
  props: { news: "corner-chip", button: "icon", state: "updated", read: true },
};
for (const [button, lead] of Object.entries(BUTTONS) as [Exclude<ButtonLook, "card">, string][])
  for (const [state, note] of Object.entries(STATES) as [Exclude<State, "updated">, string][])
    variants[`button-${button}-${state}`] = { note: `${lead} ${note}`, props: { news: "corner-chip", button, state } };

export default componentEntry<Props>({
  id: "pages.changelog.update-footprint",
  title: "What’s New on New Tab, update button in the footer (prototype)",
  area: "Pages",
  experimental: true,
  height: 800,
  covers: ["pages/changelog/UpdateSurfaces.tsx#UpdatedCard"],
  keywords: ["update", "pill", "what's new", "footer", "sidebar", "new tab", "layout shift", "restart"],
  load: async () => UpdateFootprintGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
    await import("../../ui/glass/composerMaterial.css");
    await import("./updateSurfaces.css");
    await import("./UpdateFootprint.gallery.css");
  },
  variants,
});
