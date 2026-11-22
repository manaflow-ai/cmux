// l10n-allow-file: gallery-only sample chats and proposal labels, not shipped UI.
//
// A review board for where a chat's state and its next action should show (acpmux `rollingSummary`,
// hub/rolling_summary.rs). Leo, 2026-11-22, of the header line a24d951903b5 added: "why do we have
// this subheading here? im not sure if this is useful. well, at least for 1, it's overlapping. it's
// not good. idk why this was put in." and "beyer is like... directionally right. Executionally/even
// in decisions, we cannot simply defer to dude everywhere."
//
// Data-only mocks: no variant here changes the live header (ChatSummaryLine stays as it is until
// Leo picks). "today" draws the real ChatSummaryLine with the text Leo saw, for comparison.
import { useState, type ReactNode } from "react";
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { ChatSummaryLine } from "./ChatSummaryLine";

type Placement = "today" | "sidebar-only" | "chip" | "chip-open" | "short-line" | "tab-hover";
type Props = { placement: Placement };

type Chat = {
  title: string;
  /** What the daemon wrote before this change: the wrap-up recap's first sentence. */
  raw: string;
  rawNext?: string;
  /** A state and an imperative of at most ~6 words each (the tightened rolling_summary.rs). */
  state: string;
  next?: string;
  updated: string;
  status: "idle" | "running" | "needs-you";
};

// Leo's real example first (his 2026-11-22 05:03Z screenshot), then two of other shapes.
const CHATS: Chat[] = [
  {
    title: "claude-coord",
    raw: "I posted build-mac's 14-day permission-stall history on #7645 (https://github.com/example/repo/issues/7645). The stalls cluster around auto-mode refusals.",
    rawNext: "Want me to draft the auto-mode allowlist change?",
    state: "Stall history posted on #7645",
    next: "OK to draft allowlist change?",
    updated: "2m ago",
    status: "needs-you",
  },
  {
    title: "Parser fix",
    raw: "Fixed the parser and pushed it. CI is still running.",
    rawNext: "Merge the PR once CI is green",
    state: "CI green, PR #412 open",
    next: "Merge PR #412",
    updated: "14m ago",
    status: "idle",
  },
  {
    title: "Investigate the flaky reconnect path",
    raw: "Found the reconnect race in the link controller: a retry starts before the old socket closes, so two sessions fight.",
    rawNext: "Review the fix and run the fleet reconnect suite",
    state: "Reconnect race found, fix drafted",
    next: "Run the fleet reconnect suite",
    updated: "running",
    status: "running",
  },
];
const LEO = CHATS[0]!;

function Tools() {
  return (
    <span className="chs-tools" aria-label="Header tools">
      <span className="chs-tool chs-tool--pill">PR #7651</span>
      <span className="chs-tool" aria-hidden="true">
        ◫
      </span>
      <span className="chs-tool" aria-hidden="true">
        •••
      </span>
    </span>
  );
}

function Tab({ chat, active }: { chat: Chat; active?: boolean }) {
  return (
    <span className="chs-tab" data-active={active ? "" : undefined}>
      <span className="chs-dot" data-status={chat.status} aria-hidden="true" />
      <span className="chs-tab__title">{chat.title}</span>
    </span>
  );
}

function Transcript() {
  return (
    <div className="chs-transcript">
      <div className="chs-user">post the 14-day stall history on #7645</div>
      <div className="chs-reply">
        I posted build-mac's 14-day permission-stall history on #7645. The stalls cluster around auto-mode refusals;
        three of the eleven were mine. Want me to draft the auto-mode allowlist change?
      </div>
      <div className="chs-composer">Message claude-coord</div>
    </div>
  );
}

/** The pane: a tab row (the native tabs, mocked) with the header's tools, then the chat. */
function Pane({ accessory, below }: { accessory?: ReactNode; below?: ReactNode }) {
  return (
    <section className="chs-pane">
      <div className="chs-tabrow">
        <span className="chs-tabs">
          <Tab chat={LEO} active />
          <Tab chat={CHATS[1]!} />
        </span>
        <span className="chs-tabrow__end">
          {accessory}
          <Tools />
        </span>
      </div>
      {below}
      <Transcript />
    </section>
  );
}

function Next({ next }: { next: string }) {
  return (
    <span className="chs-next">
      <span className="chs-next__label">Next</span>
      <span className="chs-next__text">{next}</span>
    </span>
  );
}

/** (today) The live header as Leo saw it: the real ChatSummaryLine, fed the recap's first sentence. */
function Today() {
  return (
    <Pane
      accessory={
        <span className="acpmux-shell chs-live">
          <ChatSummaryLine summary={{ text: LEO.raw, next: LEO.rawNext }} inline />
        </span>
      }
    />
  );
}

/** (a) No header line. State and next live where you choose between chats: the sidebar's
 *  Expanded rows and its hover card (native SwiftUI today, mocked here). */
function SidebarOnly() {
  return (
    <div className="chs-split">
      <aside className="chs-sidebar" aria-label="Sidebar (mock)">
        {CHATS.map((chat, i) => (
          <div className="chs-row" data-hovered={i === 0 ? "" : undefined} key={chat.title}>
            <span className="chs-row__head">
              <span className="chs-dot" data-status={chat.status} aria-hidden="true" />
              <span className="chs-row__title">{chat.title}</span>
              <span className="chs-row__time">{chat.updated}</span>
            </span>
            <span className="chs-row__line">
              {chat.state}
              {chat.next && <span className="chs-row__next"> → {chat.next}</span>}
            </span>
          </div>
        ))}
        <div className="chs-card chs-card--sidebar" role="tooltip">
          <strong className="chs-card__title">{LEO.title}</strong>
          <span className="chs-card__state">{LEO.state}</span>
          {LEO.next && <Next next={LEO.next} />}
          <span className="chs-card__meta">Needs you · {LEO.updated}</span>
        </div>
      </aside>
      <Pane />
    </div>
  );
}

/** (b) A chip before the tools: only the next action, a few words; a click opens state + next. */
function Chip({ open: startOpen }: { open: boolean }) {
  const [open, setOpen] = useState(startOpen);
  return (
    <Pane
      accessory={
        <span className="chs-chip-anchor">
          <button
            type="button"
            className="chs-chip"
            data-status={LEO.status}
            aria-expanded={open}
            onClick={() => setOpen((v) => !v)}
          >
            <span className="chs-dot" data-status={LEO.status} aria-hidden="true" />
            <span className="chs-chip__text">{LEO.next}</span>
            <span className="chs-chip__short">Next</span>
          </button>
          {open && (
            <span className="chs-card chs-card--chip" data-chip-card="">
              <span className="chs-card__eyebrow">Where it stands</span>
              <span className="chs-card__state">{LEO.state}</span>
              {LEO.next && <Next next={LEO.next} />}
              <span className="chs-card__meta">From the agent's wrap-up · {LEO.updated}</span>
            </span>
          )}
        </span>
      }
    />
  );
}

/** (c) Genuinely short text: state, then a visible "Next" label and the action; shown for three
 *  chats so the lengths compare. */
function ShortLine() {
  return (
    <div className="chs-stack">
      {CHATS.map((chat) => (
        <section className="chs-pane chs-pane--own-row" key={chat.title}>
          <div className="chs-ownrow">
            <span className="chs-ownrow__title">{chat.title}</span>
            <span className="chs-short">
              <span className="chs-short__state">{chat.state}</span>
              {chat.next && <Next next={chat.next} />}
            </span>
            <Tools />
          </div>
        </section>
      ))}
    </div>
  );
}

/** (d) The tab's hover card: name, state and next under the tab, nothing in the header at rest. */
function TabHover() {
  return (
    <Pane
      below={
        <span className="chs-card chs-card--tab" role="tooltip">
          <strong className="chs-card__title">{LEO.title}</strong>
          <span className="chs-card__state">{LEO.state}</span>
          {LEO.next && <Next next={LEO.next} />}
          <span className="chs-card__meta">Claude · Opus · needs you · {LEO.updated}</span>
        </span>
      }
    />
  );
}

function ChatSummaryPlacements({ placement }: Props) {
  return (
    <div className="chs-gallery" data-chs-gallery data-placement={placement}>
      {placement === "today" && <Today />}
      {placement === "sidebar-only" && <SidebarOnly />}
      {placement === "chip" && <Chip open={false} />}
      {placement === "chip-open" && <Chip open />}
      {placement === "short-line" && <ShortLine />}
      {placement === "tab-hover" && <TabHover />}
    </div>
  );
}

const variant = (placement: Placement, note: string): Record<string, ComponentVariant<Props>> => ({
  [placement]: { note, props: { placement } },
});

export default componentEntry<Props>({
  id: "agent-pane.chat-summary-placements",
  title: "Chat state and next action: placements",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 300,
  widths: { narrow: 420, normal: 760, wide: 1040 },
  anchors: [{ selector: "[data-chs-gallery]" }],
  covers: ["agent-session/acpmux/header/header.css#acpmux-chat-summary"],
  styles: () =>
    Promise.all([import("../styles.css"), import("./header.css"), import("./ChatSummaryPlacements.gallery.css")]),
  load: async () => ChatSummaryPlacements,
  variants: {
    ...variant(
      "today",
      "Today, for comparison: the real ChatSummaryLine in the tab row, fed the wrap-up recap's first sentence, as in Leo's 2026-11-22 screenshot. It repeats the reply below it and its next action is cut off.",
    ),
    ...variant(
      "sidebar-only",
      "(a) No header line. The state and next action show where you pick between chats: the sidebar's Expanded rows and its hover card (native; mocked).",
    ),
    ...variant(
      "chip",
      '(b) A chip before the tools: the next action only, a few words, with the chat\'s status dot. Never more than ~200px; under ~520px of row it folds to the dot and "Next", so the tabs and tools keep their room.',
    ),
    ...variant("chip-open", "(b) The chip clicked: state, next action, and where the line came from."),
    ...variant(
      "short-line",
      "(c) Genuinely short text in the own-row header: a state of ~6 words and a labelled Next of ~6 words, for three chats.",
    ),
    ...variant(
      "tab-hover",
      "(d) Nothing in the header at rest; the tab's hover card names the state and the next action (with the sidebar's card and rows, as (a)).",
    ),
  },
});
