// l10n-allow-file: gallery fixtures (public-safe sample chats), not shipped UI.
// Leo, 2026-11-24: "terminal agent chats. can they be demarcated a bit differently/should they? than gui
// agent chats. both of them rn are just claude icon. but one is terminal one is gui. should we do
// anything? how? a small subscript symbol? but wouldn't that look kinda dingleberry-esque?"
// Four answers (TerminalChatMark.tsx), each in three lists that mix terminal and GUI chats: a web replica of
// the Mac sidebar row (AppKit, Default density: SidebarStyle, SidebarRowTuning, DensityPreset's reference
// tokens), the web sidebar chat history row (pages/sidebar-chats, its own stylesheet and metrics) and a web
// replica of the iOS chat row (AgentChatsScreen.swift `AgentChatRow`). `today` is what every row draws now.
import type { CSSProperties, ReactNode } from "react";
import { componentEntry } from "../../gallery/format";
import { FIXTURE_METRICS } from "../../pages/sidebar-chats/fixtures";
import { AgentMark } from "./AgentMark";
import { TerminalChatMark, terminalChatDetail, type TerminalChatMarkVariant } from "./TerminalChatMark";

export type Look = TerminalChatMarkVariant | "today";
export type Platform = "mac" | "web" | "ios";

export type SampleChat = {
  title: string;
  harness: "claude-code" | "codex";
  terminal: boolean;
  folder: string;
  age: string;
  status?: "running" | "waiting";
  selected?: boolean;
};

export const SAMPLE_CHATS: SampleChat[] = [
  { title: "Fix the flaky restore test", harness: "claude-code", terminal: true, folder: "~/cmux", age: "2m", selected: true },
  { title: "Port the palette ranker", harness: "codex", terminal: false, folder: "~/cmux", age: "14m", status: "running" },
  { title: "Draft the release notes", harness: "claude-code", terminal: false, folder: "~/docs", age: "1h" },
  { title: "Bump ghostty, rerun the bench", harness: "codex", terminal: true, folder: "~/ghostty", age: "3h", status: "waiting" },
  { title: "Why does the dock flicker", harness: "claude-code", terminal: true, folder: "~/cmux", age: "1d" },
];

const TERMINAL = "Terminal";

/** The second line every list reads today (iOS's `subtitle`: status, then folder). */
function detailOf(chat: SampleChat): string {
  const status = chat.status === "waiting" ? "Needs you" : chat.status === "running" ? "Working" : "";
  return [status, chat.folder].filter(Boolean).join(" · ");
}

function lineFor(look: Look, chat: SampleChat, detail: string | null): string | null {
  return look === "label" && chat.terminal ? terminalChatDetail(TERMINAL, detail) : detail;
}

function Mark(props: { look: Look; chat: SampleChat; size: number; slot?: number; tint?: boolean; onDark?: boolean; ground?: string }) {
  const { look, chat, size, slot, tint, onDark, ground } = props;
  if (look === "today" || !chat.terminal) {
    const side = slot ?? size;
    return (
      <span className="tcm-slot" style={{ width: side, height: side }}>
        <AgentMark agent={chat.harness} size={size} tint={tint} onDark={onDark} reserve />
      </span>
    );
  }
  return (
    <TerminalChatMark
      agent={chat.harness}
      size={size}
      slot={slot}
      variant={look}
      tint={tint}
      onDark={onDark}
      ground={ground}
    />
  );
}

/// The Mac sidebar's workspace row at Default density, as a web replica: a 44 pt two-line fill (30 pt row plus
/// the 14 pt caption line), 6 pt from the sidebar's edges, 7 pt content inset, the 16 pt leading glyph, a 7 pt gap,
/// the 14 pt title, the 11 pt detail line, a 9 pt corner, 2 pt between rows, the 8 pt status dot trailing.
function MacList({ look, chats }: { look: Look; chats: SampleChat[] }) {
  return (
    <div className="tcm-mac" data-platform="mac">
      {chats.map((chat) => (
        <div key={chat.title} className="tcm-mac-row" data-selected={chat.selected || undefined} data-terminal={chat.terminal || undefined}>
          <span className="tcm-mac-icon">
            <Mark look={look} chat={chat} size={16} tint ground={chat.selected ? "var(--tcm-selected-ground)" : undefined} />
          </span>
          <span className="tcm-mac-text">
            <span className="tcm-mac-title">{chat.title}</span>
            <span className="tcm-mac-detail">{lineFor(look, chat, chat.folder)}</span>
          </span>
          {chat.status ? <span className="tcm-dot" data-status={chat.status} /> : null}
        </div>
      ))}
    </div>
  );
}

/// The web sidebar chat history (pages/sidebar-chats): its own `.sc-*` stylesheet and fixture metrics (28 px row,
/// 14 px glyph in a 16 box at x 8, title at x 32, 13 px title, 11 px age). The page's ChatRow is not exported, so
/// this is its markup with the same classes. A row has one line, so the label form leads the age.
function WebList({ look, chats }: { look: Look; chats: SampleChat[] }) {
  const m = FIXTURE_METRICS;
  const vars = {
    "--sc-row": `${m.row}px`,
    "--sc-spacing": `${m.spacing}px`,
    "--sc-radius": `${m.radius}px`,
    "--sc-icon-x": `${m.iconX}px`,
    "--sc-icon-box": `${m.iconBox}px`,
    "--sc-text-x": `${m.textX}px`,
    "--sc-edge": `${m.edge}px`,
    "--sc-title-size": `${m.titleSize}px`,
    "--sc-meta-size": `${m.metaSize}px`,
  } as CSSProperties;
  return (
    <section className="sc-block tcm-web" data-platform="web" style={vars}>
      {chats.map((chat) => (
        <div key={chat.title} className="sc-row" data-selected={chat.selected || undefined} data-terminal={chat.terminal || undefined}>
          <span className="sc-mark">
            <Mark look={look} chat={chat} size={m.glyph} tint ground={chat.selected ? "var(--tcm-selected-ground)" : undefined} />
          </span>
          <span className="sc-title">{chat.title}</span>
          <span className="sc-meta">{lineFor(look, chat, chat.age)}</span>
        </div>
      ))}
    </section>
  );
}

/// The iOS chat row (AgentChatsScreen.swift `AgentChatRow`), as a web replica: the brand mark at 20 in a 32 frame on a
/// 6% label circle, 12 between it and the text, the 17 pt body title, the 13 pt footnote line (a 6 pt status dot, then
/// status and folder), the age trailing; 16 pt list insets, 11 pt above and below.
function IOSList({ look, chats, dark }: { look: Look; chats: SampleChat[]; dark?: boolean }) {
  return (
    <div className="tcm-ios" data-platform="ios">
      {chats.map((chat) => {
        const circle = look === "today" || !chat.terminal || look !== "tile";
        return (
          <div key={chat.title} className="tcm-ios-row" data-selected={chat.selected || undefined} data-terminal={chat.terminal || undefined}>
            <span className={circle ? "tcm-ios-frame tcm-ios-circle" : "tcm-ios-frame"}>
              <Mark look={look} chat={chat} size={20} slot={32} onDark={dark} ground="var(--tcm-ios-ground)" />
            </span>
            <span className="tcm-ios-text">
              <span className="tcm-ios-title">{chat.title}</span>
              <span className="tcm-ios-detail">
                {chat.status ? <span className="tcm-ios-dot" data-status={chat.status} /> : null}
                {lineFor(look, chat, detailOf(chat))}
              </span>
            </span>
            <span className="tcm-ios-age">{chat.age}</span>
          </div>
        );
      })}
    </div>
  );
}

const CAPTIONS: Record<Platform, string> = {
  mac: "Mac sidebar row: a web replica of the native AppKit row (Default density metrics)",
  web: "Web sidebar chat history row (pages/sidebar-chats markup and stylesheet, 14 px glyph)",
  ios: "iOS chat row: a web replica of AgentChatsScreen's SwiftUI row (32 frame, 20 mark)",
};

export type TerminalChatMarkGalleryProps = { look: Look; platforms?: Platform[]; /** The theme side for the iOS brand marks; the page's own when omitted. */
  dark?: boolean;
  chats?: SampleChat[];
};

export function TerminalChatMarkGallery({ look, platforms = ["mac", "web", "ios"], dark, chats = SAMPLE_CHATS }: TerminalChatMarkGalleryProps) {
  const panel = (platform: Platform, body: ReactNode) => (
    <figure key={platform} className="tcm-panel" data-panel={platform}>
      <figcaption className="tcm-caption">{CAPTIONS[platform]}</figcaption>
      {body}
    </figure>
  );
  return (
    <div className="tcm-gallery" data-look={look}>
      {platforms.map((platform) =>
        platform === "mac"
          ? panel(platform, <MacList look={look} chats={chats} />)
          : platform === "web"
            ? panel(platform, <WebList look={look} chats={chats} />)
            : panel(platform, <IOSList look={look} chats={chats} dark={dark} />),
      )}
    </div>
  );
}

export default componentEntry<TerminalChatMarkGalleryProps>({
  id: "agent-pane.terminal-chat-mark",
  title: "Terminal vs GUI agent chats in list rows (four marks)",
  area: "Agent pane",
  experimental: true,
  covers: ["agent-session/shared/TerminalChatMark.tsx"],
  height: 760,
  keywords: ["terminal", "gui", "agent mark", "chat row", "badge", "tile", "chevron", "sidebar", "ios"],
  load: async () => TerminalChatMarkGallery,
  styles: async () => {
    await import("../../pages/sidebar-chats/styles.css");
    await import("./TerminalChatMark.gallery.css");
  },
  variants: {
    today: { note: "Today: terminal and GUI chats draw the same bare mark.", props: { look: "today" } },
    label: { note: "(a) Mark unchanged; a terminal chat's second line starts with “Terminal · ”.", props: { look: "label" } },
    tile: { note: "(b) Terminal chats: the mark in the terminal's foreground on a tile of the terminal's background.", props: { look: "tile" } },
    chevron: { note: "(c) Terminal chats: a monospace prompt chevron before the mark.", props: { look: "chevron" } },
    badge: { note: "(d) Terminal chats: the pack's terminal glyph as a cutout badge at the mark's bottom right.", props: { look: "badge" } },
  },
});
