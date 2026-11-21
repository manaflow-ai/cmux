// The Messages page's props contract: what the shell hands the parts that plug into it (the
// transcript, the sheets and the in-chat cards). The data types are the Channels data layer's own
// (home-channels/types.ts, model.ts, store.ts), re-exported here so every part types against one
// place and nothing forks them.
import type { ReactNode } from "react";
import type { HomeChannelsStore, HomeSnapshot } from "../home-channels/store";
import type { HomeConversation, HomeParticipant } from "../home-channels/types";
import type { Strings } from "../shared/i18n";
import type { PageClient } from "../shared/pageClient";

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
}

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
}

/** The detail slot: the shell calls it with the open conversation's props. */
export type MessagesDetail = (props: MessagesDetailProps) => ReactNode;
