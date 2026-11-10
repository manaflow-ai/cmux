// The Messages page's props contract: what the shell hands the parts that plug into it (the
// transcript, the sheets and the in-chat cards). The data types are the Channels data layer's own
// (home-channels/types.ts, model.ts, store.ts), re-exported here so every part types against one
// place and nothing forks them.
import type { ReactNode } from "react";
import type { HomeChannelsStore, HomeSnapshot } from "../home-channels/store";
import type { HomeConversation, HomeParticipant } from "../home-channels/types";
import type { Strings } from "../shared/i18n";
import type { PageClient } from "../shared/pageClient";
import type { Rect } from "./list/layout";
import type { MessagesNav } from "./nav";

export type {
  ConversationKind,
  HomeAttachment,
  HomeCapabilities,
  HomeChief,
  HomeConversation,
  HomeMessage,
  HomeParticipant,
  HomePart,
  HomeThreadStats,
} from "../home-channels/types";
export type { HomeDraft } from "../home-channels/drafts";
export type { ChiefState, TimelineRow, Unseen } from "../home-channels/model";
export type { HomeChannelsStore, HomeSnapshot, PendingSend } from "../home-channels/store";
export type { ListItem, ListModel } from "./list/model";
export type { Rect } from "./list/layout";

/** One item of a host menu: a catalog action with the registry's title. */
export interface HostMenuItem {
  id: string;
  title: string;
  /** The catalog action id (`home.chatColors`, `home.leaveConversation`, ...). */
  action: string;
  arguments?: Record<string, string | boolean>;
  destructive?: boolean;
  checked?: boolean;
  separatorBefore?: boolean;
}

/** What only the app knows: the window's traffic lights over the page's top-left (page points), or
 * null when none lie over it (full screen, the window's sidebar open beside the page). */
export interface MessagesChrome {
  windowControls: { x: number; y: number; width: number; height: number } | null;
  /** The unread dot's colour (`#rrggbb`): the person's `notifications.attention.color`, else the
   * notification blue, as the native list draws it. Absent: the theme's accent. */
  unreadColor?: string;
}

/** The host bridge (host.ts): the app's menus and actions, and its chrome. */
export interface MessagesHost {
  menu(kind: "row" | "compose", conversation?: string): Promise<HostMenuItem[]>;
  perform(item: HostMenuItem): Promise<void>;
  subscribeChrome(listener: (chrome: MessagesChrome) => void): () => void;
  /** The conversations deleted from the list (Delete Conversation…), each with its newest message's
   * seq then: one stays off the list until a newer message. Sent on subscribe and on every change. */
  subscribeHidden(listener: (hidden: HiddenConversations) => void): () => void;
  /** The list's app facts (tags, the Cloud note, teammates, header sizes); sent on subscribe and on change. */
  subscribeList(listener: (facts: ListFacts) => void): () => void;
  /** The list's width kept for this window (null: the standard width). */
  loadWidth(): Promise<number | null>;
  /** The person's drag set the width (null: the divider's double-click put it back). */
  saveWidth(width: number | null): void;
  /** The list header's band and its controls, in page points: the band's empty space moves the window. */
  setDragBand(band: Rect, controls: readonly Rect[]): void;
}

/** A person the list offers to chat to (a teammate with no DM yet). */
export interface ListPerson {
  id: string;
  name: string;
}

/** The list header's sizes at the sidebar's density and text size (the native `HomeSidebarHeaderMetrics`). */
export interface HeaderMetrics {
  side: number;
  chipHeight: number;
  chipGap: number;
  chipPadding: number;
  /** Points added to the chip's and the empty list's text. */
  textStep: number;
}

/** What the app adds to the list (`cmux.home.messages.list`, HomeMessagesListFeed.swift). */
export interface ListFacts {
  /** Each conversation's tag after its name: a Chief's "Main · Cloud", "This Mac" or engine. */
  badges: ReadonlyMap<string, string>;
  /** The quiet line under the list (Cloud conversations not reachable). */
  note?: string;
  /** The team members with no DM yet: rows after the conversations while no search runs. */
  teammates: readonly ListPerson[];
  /** Everyone with no DM yet: a search lists the matches under "Teammates". */
  people: readonly ListPerson[];
  /** Absent: the Compact sizes with the default text. */
  header?: HeaderMetrics;
}

/** Deleted conversations by id, with the newest seq each had when deleted. */
export type HiddenConversations = ReadonlyMap<string, number>;

/** What the shell's detail slot gets: the open conversation and everything to draw and change it.
 * The transcript (`transcript/`), the cards (`cards/`) and the sheets (`sheets/`) take these. */
export interface MessagesDetailProps {
  store: HomeChannelsStore;
  snapshot: HomeSnapshot;
  /** The open conversation, or undefined (none yet, or the New Message page). */
  conversation?: HomeConversation;
  me?: HomeParticipant;
  strings: Strings;
  /** The app host (null in a browser). */
  host: PageClient | null;
  messages: MessagesHost;
  chrome: MessagesChrome;
  /** The person opened the conversation (a click or Return in the list): the composer takes the keyboard. */
  openedAt?: number;
  /** The page's view state the list shares: New Message, the sheet, drafts, the keyboard. */
  nav: MessagesNav;
  /** The one conversation this page shows (a conversation tab, the Chief panel: `#/conversation/<id>`):
   * no list, and a conversation link opens through the host instead of here. */
  single?: string;
}

/** The detail slot: the shell calls it with the open conversation's props. */
export type MessagesDetail = (props: MessagesDetailProps) => ReactNode;
