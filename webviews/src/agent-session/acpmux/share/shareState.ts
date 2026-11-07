// Who a chat is shared with, read from the host's `share.op` (design chat-multiplayer.md 2, "Share
// dialog"; Leo, 2026-11-07: "like being able to share Google Docs, right?"). The daemon owns every
// share (agent_session_shares.rs); the host forwards `share.op` to it for this pane's own chat and
// never takes a chat from the page. This module only reads its answer into the dialog's rows and
// names the steps: people (accounts invited with a role), General access (an Anyone-with-the-link
// link, or none), and the link Copy link puts on the clipboard.
//
// The Anyone link is made with role `talk` (contract of ask-2a1105b933: a guest signed in to cmux
// joins as their account and may send, each message held for the owner's Approve; an anonymous
// guest still only watches, which the daemon enforces). Leo, 2026-11-07: "if you imagine the Google
// Docs sharing flow, you just come in with your Gmail account and that's it".
import { postNative } from "../native";

export type ShareRole = "view" | "talk";
export type GeneralAccess = "restricted" | "anyone";

export interface ShareGuest {
  guestId: string;
  name: string;
  account: string | null;
  role: ShareRole | null;
  joined: boolean;
}

export interface ShareInvitee {
  account: string;
  role: ShareRole;
  state: string;
  joined: boolean;
}

/** One share of the chat, as the host answers `share.op {op: "state"}`. */
export interface ChatShare {
  shareId: string;
  state: string;
  url: string | null;
  inviteUrl: string | null;
  /** The role the link was made for: `talk` for a dialog's Anyone with the link (signed-in guests
   * may send, anonymous ones watch), `view` for a viewers-only link (or one made by an older
   * dialog); null for a link made elsewhere (Share with Guest…). */
  role: ShareRole | null;
  createdAt: number;
  expiresAt: number;
  usesLeft: number;
  guests: ShareGuest[];
  invitees: ShareInvitee[];
}

/** A person with access, one row of the dialog. */
export interface SharePerson {
  account: string;
  role: ShareRole;
  /** A device of theirs has the chat open now. */
  joined: boolean;
}

export interface ShareView {
  people: SharePerson[];
  general: GeneralAccess;
  /** The live Anyone-with-the-link shares, `view` and `talk` (Restricted ends them). */
  links: ChatShare[];
  /** The link invitees open (`<room>/i/<share>`, no secret); null until someone is invited. */
  inviteUrl: string | null;
  /** Link guests in the chat now (not invitees). */
  guestsNow: number;
}

const live = (share: ChatShare) => share.state === "active" || share.state === "provisioning";

/** The dialog's rows from the chat's shares: invitees across live shares (oldest first, one row per
 * account), viewer links, and the invite link of the newest live share that has invitees. */
export function shareView(shares: readonly ChatShare[]): ShareView {
  const open = shares.filter(live);
  const people = new Map<string, SharePerson>();
  for (const share of open) {
    for (const invitee of share.invitees) {
      if (invitee.state !== "invited") continue;
      const joined = share.guests.some((guest) => guest.joined && guest.account === invitee.account);
      const known = people.get(invitee.account);
      if (known) known.joined ||= joined;
      else people.set(invitee.account, { account: invitee.account, role: invitee.role, joined });
    }
  }
  // Every live share made with a role is a bearer link, whatever invite records it also holds:
  // Restricted must end each one, or a link would keep working while the dialog says Restricted.
  const links = open.filter((share) => share.role === "view" || share.role === "talk");
  const inviteShare = [...open]
    .filter((share) => share.invitees.some((invitee) => invitee.state === "invited"))
    .sort((a, b) => b.createdAt - a.createdAt)[0];
  const guestsNow = links.reduce((count, share) => count + share.guests.filter((guest) => guest.joined).length, 0);
  return {
    people: [...people.values()],
    general: links.length > 0 ? "anyone" : "restricted",
    links,
    inviteUrl: inviteShare?.inviteUrl ?? null,
    guestsNow,
  };
}

/** Whether a refused op was the daemon's `share.bad_request` (an older daemon caps a talk link's uses). */
const refusedAsBadRequest = (error: unknown) => {
  const code = (error as { code?: unknown } | null)?.code;
  const message = error instanceof Error ? error.message : String(error);
  return code === "share.bad_request" || message.includes("share.bad_request");
};

/** The host's `share.op`; tests and the gallery replace it. */
export type ShareCall = (op: string, params?: Record<string, unknown>) => Promise<unknown>;

export const nativeShareCall: ShareCall = (op, params = {}) => postNative("share.op", { op, ...params });

/** A link's secret is answered only by its create (the daemon keeps its hash), so the page keeps
 * the viewer link it made for each chat while it lives; after a reload Copy link makes a new one. */
const madeLinks = new Map<string, { shareId: string; url: string }>();

/** Forgets the kept links (tests). */
export function forgetShareLinks(): void {
  madeLinks.clear();
}

/** Restricted re-reads this many times before it says a link is still live (each round ends every
 * viewer link it read, so only links made faster than a round trip outlast it). */
const RESTRICT_ROUNDS = 5;

export function shareClient(sessionId: string, host: ShareCall = nativeShareCall) {
  // Every op names the chat it is for: the host refuses one whose tab shows another chat by now, so
  // a step (a role change's two calls included) never lands on a chat the person did not share.
  const call: ShareCall = (op, params = {}) => host(op, { ...params, session: sessionId });
  return {
    async state(): Promise<ShareView> {
      const answer = (await call("state")) as { shares?: ChatShare[] } | undefined;
      return shareView(answer?.shares ?? []);
    },
    invite: (account: string, role: ShareRole) => call("invite", { account, role }),
    remove: (account: string) => call("uninvite", { account }),
    /** A role change is a remove, then an invite (the daemon refuses another role on an invited account). */
    async setRole(account: string, role: ShareRole) {
      await call("uninvite", { account });
      await call("invite", { account, role });
    },
    /** The Anyone link Copy link hands out: the one this page made while it is live, else a new one
     * (role `talk`; a daemon from before talk links took 1000 uses refuses it, and gets `view`). */
    async viewerLink(view: ShareView): Promise<string> {
      const kept = madeLinks.get(sessionId);
      if (kept && view.links.some((share) => share.shareId === kept.shareId)) return kept.url;
      const link = (role: ShareRole) =>
        call("link", { role }) as Promise<{ shareId?: string; url?: string | null } | undefined>;
      const made = await link("talk").catch((error: unknown) => {
        if (!refusedAsBadRequest(error)) throw error;
        return link("view");
      });
      if (!made?.shareId || !made.url) {
        // A share with no room has no link to hand out: end it, so each try does not leave one
        // live that counts toward the daemon's share limit.
        if (made?.shareId) await call("revoke", { shareId: made.shareId }).catch(() => undefined);
        throw new Error("share.no_room");
      }
      madeLinks.set(sessionId, { shareId: made.shareId, url: made.url });
      return made.url;
    },
    /** Restricted: every viewer link ends, and its guests leave at once (the daemon's revoke). The
     * dialog's view may be stale (another dialog can make a link meanwhile), so it re-reads the
     * daemon after revoking and ends what it finds, until a read shows no viewer link. */
    async restrict(view: ShareView) {
      madeLinks.delete(sessionId);
      let links = view.links;
      for (let round = 0; round < RESTRICT_ROUNDS; round += 1) {
        for (const share of links) await call("revoke", { shareId: share.shareId });
        const answer = (await call("state")) as { shares?: ChatShare[] } | undefined;
        links = shareView(answer?.shares ?? []).links;
        if (links.length === 0) return;
      }
      throw new Error("share.restrict_raced");
    },
    manage: () => call("manage"),
  };
}

export type ShareClient = ReturnType<typeof shareClient>;

/** Whether `text` reads as an account the daemon takes: an email address or a cmux `@handle`. */
export function isAccount(text: string): boolean {
  const value = text.trim();
  return /^@[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$/.test(value) || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}
