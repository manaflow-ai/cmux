// The forum page's data, as the daemon serves it (cmux-tui/crates/cmux-forum-hosted: model.rs). The
// daemon fetches, caches and follows the hosted feed; the page only renders a snapshot and sends
// intents. Field names follow the hosted API (`/v1/forum/*`), snake_case.

export type ForumAuthorKind = "person" | "agent";

/** Who posted: `kind`, `id`, `name`, `org` and `on_behalf_of` are what the store authenticated;
 * `session` and `host` are what the agent reported (display only, drawn faint). */
export type ForumAuthor = {
  kind: ForumAuthorKind;
  id: string;
  name: string;
  org?: string | null;
  on_behalf_of?: string | null;
  session?: string | null;
  host?: string | null;
};

export type ForumThreadKind = "question" | "finding" | "article" | "page";
export type ForumThreadState = "open" | "answered" | "closed";

export type ForumThread = {
  number: number;
  title: string;
  body: string;
  state: ForumThreadState;
  kind: ForumThreadKind;
  labels: string[];
  author: ForumAuthor;
  space: string;
  comments: number;
  created_at: number;
  updated_at: number;
  /** New since this person last opened it (the daemon's read marker). */
  unread?: boolean;
};

export type ForumComment = {
  id: number;
  thread: number;
  body: string;
  author: ForumAuthor;
  created_at: number;
};

export type ForumSpaceVisibility = "private" | "public" | "shared";

export type ForumSpace = {
  name: string;
  visibility: ForumSpaceVisibility;
  threads: number;
  unread?: number;
};

/** Where the daemon's feed follower stands: live (at head), catching up (more pages than one pull
 * reads), or offline (the last pull failed; the cursor did not move). */
export type ForumFeedState = "live" | "behind" | "offline";

export type ForumStatus = "ready" | "loading" | "off" | "signed-out";

export type ForumSnapshot = {
  status: ForumStatus;
  team: string;
  feed: ForumFeedState;
  spaces: ForumSpace[];
  threads: ForumThread[];
  /** Comments by thread number, for the threads the daemon has loaded. */
  comments: Record<number, ForumComment[]>;
};

/** The page's three layouts (the gallery's variants; one ships). */
export type ForumLayout = "columns" | "split" | "stream";

export type ForumComposerMode = "reply" | "new";
