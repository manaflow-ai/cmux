// l10n-allow-file: gallery fixture data, not shipped UI.
// The chat header's named slots (headerSlots.ts, HeaderSlotsRow.tsx): `title`, `accessory`, `trailing`. Leo, 2026-11-22:
// "the icons on the top right have gotten displaced due to putting things on a line. this is not how we should do ui.
// we need to have a proper way to do ui so that when anybody wants to adjust or customize things like this, it is done
// easily properly." Each variant draws the header with every optional item off, then on, in the header's own row and
// in the pane's tab row (the tabs stand in at the left): the trailing tools sit at the same place in each pair, and
// the accessories give way by their rule (the summary narrows, then hides; a chip hides) when the room is short.
// test/chat-header-slots-browser.test.ts holds the real header to it at every split.
import type { CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import { PresenceStack } from "../multiplayer/Faces";
import { ChatHeaderInlineStatus, ChatHeaderStatus } from "./ChatHeaderStatus";
import { ChatSummaryLine, type ChatSummary } from "./ChatSummaryLine";
import { HeaderIcon } from "./HeaderIcon";
import { HeaderItem, HeaderSlots } from "./HeaderSlotsRow";
import { HEADER_ITEMS } from "./headerSlots";
import { PullRequestChip } from "./PullRequestChip";
import { tabRowStyle } from "./tabRow";
import { ThreadTitle } from "./ThreadTitle";
import { WorktreePill } from "./WorktreePill";
import "./header.css";

type Props = { tabRow: boolean; warning?: boolean };

const SUMMARY: ChatSummary = {
  text: "I posted the build host's 14-day permission-stall history on the tracking issue",
  next: "Wait for the owner's read",
};
const PULL_REQUEST = {
  url: "https://example.com/pull/7645",
  number: 7645,
  title: "Post the stall history",
  state: "open",
  review: "",
  mergeable: "mergeable",
  checks: { state: "passing", passed: 2, total: 2 },
  checkList: [],
};
const WORKTREE = { branch: "feat/stall-history", base: "main", mainRoot: "/home/dev/uploader" };
const PEOPLE = [
  { id: "avery", name: "Avery Lee" },
  { id: "sam", name: "Sam Ortiz" },
];

function Trailing() {
  return (
    <div className="acpmux-header-tools">
      <button type="button" className="acpmux-header-tool acpmux-header-panel-toggle" aria-label="Summary">
        <HeaderIcon name="tunable.sidebar" />
      </button>
      <div className="acpmux-header-tool-group acpmux-header-tool-group-actions">
        {(["terminal", "browser", "pane.split.down"] as const).map((icon) => (
          <button key={icon} type="button" className="acpmux-header-tool" data-quick-action={icon} aria-label={icon}>
            <HeaderIcon name={icon} />
          </button>
        ))}
      </div>
      <button type="button" className="acpmux-header-tool acpmux-header-more" aria-label="More">
        <HeaderIcon name="action.more" />
      </button>
    </div>
  );
}

function Header({ tabRow, warning, on }: Props & { on: boolean }) {
  const status = on && warning ? "Couldn't open this chat" : "";
  return (
    <div
      className="acpmux-shell"
      style={{
        position: "relative",
        height: tabRow ? 28 : 36,
        ...(tabRow ? (tabRowStyle({ height: 28, trailingInset: 0 }) as CSSProperties) : {}),
      }}
    >
      {tabRow && (
        <div
          style={{
            position: "absolute",
            insetBlock: 0,
            insetInlineStart: 0,
            width: "50%",
            display: "flex",
            alignItems: "center",
            gap: 4,
            paddingInline: 6,
            boxSizing: "border-box",
            background: "color-mix(in srgb, var(--agent-text) 6%, transparent)",
            overflow: "hidden",
          }}
        >
          {["release-coordinator", "Terminal"].map((tab) => (
            <span
              key={tab}
              style={{
                flex: "0 1 140px",
                minWidth: 40,
                padding: "0 8px",
                borderRadius: 6,
                background: "color-mix(in srgb, var(--agent-text) 10%, transparent)",
                lineHeight: "20px",
                overflow: "hidden",
                whiteSpace: "nowrap",
              }}
            >
              {tab}
            </span>
          ))}
        </div>
      )}
      <div className="acpmux-stage" style={{ flex: 1, minWidth: 0 }}>
        <HeaderSlots
          inTabRow={tabRow}
          title={
            <ChatHeaderStatus status={status}>
              {!tabRow && (
                <span className="acpmux-header-status-content">
                  <ThreadTitle
                    title={
                      on ? "Investigate why the uploader's retry loop stalls after a reconnect" : "release-coordinator"
                    }
                    onRename={() => undefined}
                  />
                  <ChatSummaryLine summary={on ? SUMMARY : null} />
                </span>
              )}
            </ChatHeaderStatus>
          }
          accessory={
            on && (
              <>
                <HeaderItem id="presence">
                  <PresenceStack viewing={PEOPLE} />
                </HeaderItem>
                {tabRow && (
                  <ChatHeaderInlineStatus status={status}>
                    <ChatSummaryLine summary={SUMMARY} inline />
                  </ChatHeaderInlineStatus>
                )}
                <HeaderItem id="worktree">
                  <WorktreePill worktree={WORKTREE} />
                </HeaderItem>
                <HeaderItem id="pullRequest">
                  <PullRequestChip pullRequest={PULL_REQUEST} />
                </HeaderItem>
              </>
            )
          }
          trailing={<Trailing />}
        />
      </div>
    </div>
  );
}

function SlotsGallery(props: Props) {
  return (
    <div style={{ display: "grid", gap: 12, padding: "12px 0" }}>
      {([false, true] as const).map((on) => (
        <div key={String(on)} style={{ display: "grid", gap: 4 }}>
          <small style={{ opacity: 0.7, paddingInline: 8 }}>
            {on
              ? `Every item on (${Object.entries(HEADER_ITEMS)
                  .filter(([, spec]) => spec.slot === "accessory")
                  .map(([id, spec]) => `${id}: ${spec.overflow}`)
                  .join(", ")})`
              : "Nothing added"}
          </small>
          <Header {...props} on={on} />
        </div>
      ))}
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.header-slots",
  title: "Chat header slots",
  area: "Agent pane",
  pane: true,
  height: 160,
  // A 1512px window split to a quarter-ish, a third and a half.
  widths: { narrow: 320, normal: 504, wide: 756 },
  anchors: [{ selector: ".acpmux-header-more" }],
  covers: [
    "agent-session/acpmux/header/HeaderSlotsRow.tsx#HeaderSlots",
    "agent-session/acpmux/header/HeaderSlotsRow.tsx#HeaderItem",
  ],
  keywords: ["header", "slots", "accessory", "trailing", "overflow", "summary"],
  styles: () => Promise.all([import("../styles.css"), import("./header.css")]),
  load: async () => SlotsGallery,
  variants: {
    "own-row": {
      props: { tabRow: false },
      note: "The header's own row: the title and summary truncate; the accessories give way before the tools move.",
    },
    "tab-row": {
      props: { tabRow: true },
      note: "In the pane's tab row: the summary takes only the room the tools leave in the half the tabs give up.",
    },
    "tab-row-warning": {
      props: { tabRow: true, warning: true },
      note: "A warning leads the tools in the tab row, as an accessory: it truncates, the tools stay.",
    },
  },
});
