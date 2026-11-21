// The values the Messages sheets show and the outcomes their actions end with, ported from
// CmuxNextHome (HomeComposeOutcome, HomeGroupOutcome, HomeTeamSeatImpact, HomeTeamInviteFailure,
// HomeMessageRequest, HomeGroupInfo, HomeGroupMember, ChiefBackend), with the same strings. The
// host sends these shapes on the wire (`kind` plus the case's fields).
import type { Strings } from "../../shared/i18n";
import type { HomeContact } from "./recipients";

// ---------- Starting a conversation, sending an invite ----------

export type ComposeOutcome =
  /** The conversation exists; the page shows it. */
  | { kind: "opened"; conversation: string }
  /** The invite went out (in its own DM when the owner made one). */
  | { kind: "invited"; conversation?: string }
  /** The owner refused a person the user cannot reach (`not_reachable`). */
  | { kind: "notReachable"; name: string }
  | { kind: "rateLimited" }
  | { kind: "invalidAddress"; text: string }
  /** The owner is offline: nothing was sent. */
  | { kind: "offline" }
  /** Sent, but cmux Cloud did not answer: the store may still resend it. */
  | { kind: "cloudUnreachable" }
  /** Refused for another reason, shown as is ("" reads as the generic failure). */
  | { kind: "refused"; reason: string };

/** What a sheet says after a start or an invite; null when it closes. */
export function composeMessage(outcome: ComposeOutcome, strings: Strings): string | null {
  const { t, format } = strings;
  switch (outcome.kind) {
    case "opened":
      return null;
    case "invited":
      return t("home.outcome.invited");
    case "notReachable":
      return format("home.outcome.notReachable", outcome.name);
    case "rateLimited":
      return t("home.outcome.rateLimited");
    case "invalidAddress":
      return format("home.outcome.invalidAddress", outcome.text);
    case "offline":
      return t("home.outcome.offline");
    case "cloudUnreachable":
      return t("home.outcome.cloudUnreachable");
    case "refused":
      return outcome.reason ? format("home.outcome.refused", outcome.reason) : t("home.outcome.failed");
  }
}

/** The conversation a finished action shows (an opened one, a sent invite's DM), or undefined
 * when the sheet stays open and says why. `closes` is true for both kinds that close it. */
export function composeCloses(outcome: ComposeOutcome): { closes: boolean; conversation?: string } {
  if (outcome.kind === "opened") return { closes: true, conversation: outcome.conversation };
  if (outcome.kind === "invited") return { closes: true, conversation: outcome.conversation };
  return { closes: false };
}

/** A refused invite's owner code, as the user reads it (never the raw code). */
export function inviteRefusal(code: string, strings: Strings): ComposeOutcome {
  const key =
    code === "invite.blocked" || code === "invite.recipient_limited"
      ? "home.outcome.inviteBlocked"
      : code === "invite.rate_limited"
        ? "home.outcome.inviteRateLimited"
        : code === "home.not_configured"
          ? "home.outcome.inviteUnavailable"
          : "home.outcome.failed";
  return { kind: "refused", reason: strings.t(key) };
}

// ---------- Invite to Team ----------

/** What one more member costs a team: the confirmation line of Invite to Team. */
export type SeatImpact =
  | { kind: "paidSeat"; members: number }
  | { kind: "capped"; members: number; limit: number }
  | { kind: "free"; members: number }
  | { kind: "unknown" }
  | { kind: "notAllowed" };

/** Send may go: false only when the team refuses this person's invites. */
export const seatAllowsSending = (impact: SeatImpact) => impact.kind !== "notAllowed";

/** The impact for a team's billing facts (HomeTeamSeatImpact.of). */
export function seatImpactOf(facts: {
  canInvite: boolean;
  planId?: string | null;
  hasSubscription: boolean;
  memberCount: number;
  memberLimit?: number | null;
}): SeatImpact {
  if (!facts.canInvite) return { kind: "notAllowed" };
  if (typeof facts.memberLimit === "number")
    return { kind: "capped", members: facts.memberCount, limit: facts.memberLimit };
  if (facts.hasSubscription && facts.planId?.toLowerCase() === "team")
    return { kind: "paidSeat", members: facts.memberCount };
  if (facts.hasSubscription) return { kind: "unknown" };
  return { kind: "free", members: facts.memberCount };
}

export function seatImpactLine(impact: SeatImpact, strings: Strings): string {
  const { t, format } = strings;
  switch (impact.kind) {
    case "paidSeat":
      return t("home.teamInvite.paidSeat");
    case "capped":
      return format("home.teamInvite.capped", String(impact.members), String(impact.limit));
    case "free":
      return t("home.teamInvite.free");
    case "unknown":
      return t("home.teamInvite.unknown");
    case "notAllowed":
      return t("home.teamInvite.notAllowed");
  }
}

/** How one team invite went (the team API's answer). */
export type TeamInviteResult =
  | { kind: "sent" }
  | { kind: "alreadyMember" }
  | { kind: "sendFailed" }
  | { kind: "notAllowed" }
  | { kind: "unreachable" };

/** The dialog's outcome words for a team invite to `email` (HomeTeamInviteRun.invite). */
export function teamInviteOutcome(result: TeamInviteResult, email: string, strings: Strings): ComposeOutcome {
  switch (result.kind) {
    case "sent":
      return { kind: "invited" };
    case "alreadyMember":
      return { kind: "refused", reason: strings.format("home.teamInvite.alreadyMember", email) };
    case "sendFailed":
      return { kind: "refused", reason: strings.format("home.teamInvite.sendFailed", email) };
    case "notAllowed":
      return { kind: "refused", reason: strings.t("home.teamInvite.notAllowed") };
    case "unreachable":
      return { kind: "cloudUnreachable" };
  }
}

// ---------- Message requests ----------

/** Someone the user is not connected to invited them into a DM or a group. Names and text only;
 * `conversation` is the one id, never shown. */
export interface MessageRequest {
  conversation: string;
  inviter: string;
  isGroup: boolean;
  title?: string;
  /** The inviter's newest message, or "". */
  preview: string;
  /** The inviter has the user's company email domain. */
  trusted: boolean;
}

export type RequestAnswer = "accept" | "decline" | "block";

// ---------- Group info ----------

export type ChiefReplyPolicy = "auto" | "mentions" | "all";
export const CHIEF_REPLY_POLICIES: readonly ChiefReplyPolicy[] = ["auto", "mentions", "all"];

export type MemberRole = "owner" | "admin" | "member" | "readOnly";

/** One person (or agent) of a DM or group. */
export interface GroupMember {
  id: string;
  /** Empty when the owner sent none. */
  name: string;
  isMe: boolean;
  isAgent: boolean;
  /** Invited by email and not joined yet. */
  isInvited: boolean;
  role?: MemberRole;
}

/** What the group info sheet shows of one DM or group. */
export interface GroupInfo {
  conversation: string;
  isGroup: boolean;
  /** The name the owner holds; empty when it shows the members' names. */
  title: string;
  /** The name the list row shows. */
  displayTitle: string;
  /** Me first, then the others in the owner's order. */
  members: GroupMember[];
  canMute: boolean;
  muted: boolean;
  /** A large group's member count (`members` is then a roster). */
  memberCount?: number;
  /** When the group's Chiefs answer; absent hides the row. */
  chiefReplies?: ChiefReplyPolicy;
  /** Add People… and Remove are offered (defaults to `isGroup`). */
  canAddPeople?: boolean;
  /** The name can be changed (defaults to `isGroup`). */
  canRename?: boolean;
}

export const canAddPeople = (info: GroupInfo) => info.canAddPeople ?? info.isGroup;
export const canRenameGroup = (info: GroupInfo) => info.canRename ?? info.isGroup;

/** The members list's header: "Members", or "5,000 members" for a large group. */
export function membersHeader(info: GroupInfo, strings: Strings): string {
  if (info.memberCount === undefined) return strings.t("home.info.members");
  return strings.format("home.info.memberCount", info.memberCount.toLocaleString(strings.language));
}

/** The tags after a member's name: You, the role (Owner, Admin, Read-only), Agent, Invited. */
export function memberTags(member: GroupMember, strings: Strings): string[] {
  const { t } = strings;
  const tags: string[] = [];
  if (member.isMe) tags.push(t("home.info.you"));
  if (member.role === "owner") tags.push(t("home.info.role.owner"));
  if (member.role === "admin") tags.push(t("home.info.role.admin"));
  if (member.role === "readOnly") tags.push(t("home.info.role.readOnly"));
  if (member.isAgent) tags.push(t("home.info.agent"));
  if (member.isInvited) tags.push(t("home.info.invited"));
  return tags;
}

/** What a group action ended with. */
export type GroupOutcome =
  | { kind: "done" }
  | { kind: "queued" }
  | { kind: "left" }
  | { kind: "notReachable"; name: string }
  | { kind: "ownerOnly" }
  | { kind: "forbidden" }
  | { kind: "readOnly" }
  | { kind: "notAGroup" }
  | { kind: "unknownConversation" }
  | { kind: "unknownPerson"; name: string }
  | { kind: "notAMember"; name: string }
  | { kind: "cannotMute" }
  | { kind: "emptyText" }
  | { kind: "noPeople" }
  | { kind: "offline" }
  | { kind: "rateLimited" }
  | { kind: "tooMany" }
  | { kind: "refused"; reason?: string };

export const groupSucceeded = (outcome: GroupOutcome) =>
  outcome.kind === "done" || outcome.kind === "queued" || outcome.kind === "left";

/** What a group action's outcome says; null when it worked. A raw owner code is never shown. */
export function groupMessage(outcome: GroupOutcome, strings: Strings): string | null {
  const { t, format } = strings;
  switch (outcome.kind) {
    case "done":
    case "queued":
    case "left":
      return null;
    case "notReachable":
      return format("home.group.outcome.notReachable", outcome.name);
    case "unknownPerson":
      return format("home.group.outcome.unknownPerson", outcome.name);
    case "notAMember":
      return format("home.group.outcome.notAMember", outcome.name);
    case "offline":
      return t("home.outcome.offline");
    case "refused":
      return t("home.outcome.failed");
    default:
      return t(`home.group.outcome.${outcome.kind}`);
  }
}

/** Where the Add People list comes from, as its row says it. */
export const contactSourceLabel = (contact: HomeContact, strings: Strings) =>
  strings.t(contact.source === "team" ? "home.compose.source.team" : "home.compose.source.connection");

// ---------- New Chief ----------

/** One official engine a Chief runs on: the acpmux harness id, whether New Chief makes it on
 * this Mac (else the signed-in account's cloud Chief), and its name and hint keys. */
export interface ChiefBackendChoice {
  id: string;
  createsOnThisMac: boolean;
  title: string;
  hint?: string;
}

/** Every official engine, in the order the pickers offer them; the first is the default. */
export const CHIEF_BACKEND_CHOICES: readonly ChiefBackendChoice[] = [
  { id: "claude", createsOnThisMac: false, title: "home.chief.backend.claude" },
  {
    id: "codex",
    createsOnThisMac: true,
    title: "home.chief.backend.codex",
    hint: "home.chief.backend.codexHint",
  },
  { id: "muse", createsOnThisMac: true, title: "home.chief.backend.muse", hint: "home.chief.backend.museHint" },
  { id: "unii", createsOnThisMac: true, title: "home.chief.backend.unii", hint: "home.chief.backend.uniiHint" },
];

/** A Chief's name may be at most this long. */
export const CHIEF_NAME_MAX = 100;

/** Where a Chief's brain runs, as the list and the To: rows name it. */
export type ChiefPlace = { kind: "thisMac" } | { kind: "cloud" } | { kind: "server"; name: string };

export function chiefPlaceLabel(place: ChiefPlace, strings: Strings): string {
  if (place.kind === "thisMac") return strings.t("home.list.chief.thisMac");
  if (place.kind === "cloud") return strings.t("home.list.chief.cloud");
  return place.name || strings.t("home.list.chief.server");
}

/** The tag a Chief's To: row shows after "Chief": "Main · Cloud", "This Mac". */
export function chiefTag(chief: { main: boolean; place: ChiefPlace }, strings: Strings): string {
  return [chief.main ? strings.t("home.list.chief.main") : "", chiefPlaceLabel(chief.place, strings)]
    .filter(Boolean)
    .join(" · ");
}
