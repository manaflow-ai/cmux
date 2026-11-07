// The sheets' data as the host sends it (page → host reads on the `cmux.home.messages.*` route,
// HomeMessagesPage.swift), parsed into the models the sheets draw (model.ts, recipients.ts). The
// host is another build: every field is checked, an entry that is not one is dropped, and a
// missing or malformed answer reads as empty, never as an error the sheet shows.
//
//   requests.list {}              -> {requests: MessageRequest[]}
//   group.info    {conversation}  -> {info: GroupInfo, addable: HomeContact[]}
//   contacts      {}              -> {contacts: HomeContact[], inviteTeam: string | null,
//                                     pendingInvites?: string[]}
// Streams (sent on subscribe and after each change, HomeMessagesFollow.swift):
//   group.follow    {conversation}  -> group.info's answer, or {gone: true} once it is gone (the last)
//   requests.follow {}              -> requests.list's answer (subscribing reads them again)
import type { ChiefReplyPolicy, GroupInfo, GroupMember, MemberRole, MessageRequest } from "./model";
import { CHIEF_REPLY_POLICIES } from "./model";
import type { ContactSource, HomeContact } from "./recipients";

export const MessagesDataOps = {
  requests: "cmux.home.messages.requests.list",
  groupInfo: "cmux.home.messages.group.info",
  contacts: "cmux.home.messages.contacts",
  groupFollow: "cmux.home.messages.group.follow",
  requestsFollow: "cmux.home.messages.requests.follow",
} as const;

/** A follow stream's last event: what it followed is gone. */
export const isGone = (event: unknown): boolean =>
  !!event && typeof event === "object" && (event as { gone?: unknown }).gone === true;

type Json = Record<string, unknown>;

const record = (value: unknown): Json | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Json) : undefined;
const text = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);
const flag = (value: unknown): boolean => value === true;
const list = (value: unknown): unknown[] => (Array.isArray(value) ? value : []);

/** One request, or undefined when it lacks its conversation or inviter. */
export function parseMessageRequest(value: unknown): MessageRequest | undefined {
  const raw = record(value);
  const conversation = text(raw?.conversation);
  const inviter = text(raw?.inviter);
  if (!raw || !conversation || inviter === undefined) return undefined;
  const title = text(raw.title);
  return {
    conversation,
    inviter,
    isGroup: flag(raw.isGroup),
    ...(title ? { title } : {}),
    preview: text(raw.preview) ?? "",
    trusted: flag(raw.trusted),
  };
}

/** `requests.list`'s answer: the requests, in the host's order. */
export function parseRequests(answer: unknown): MessageRequest[] {
  return list(record(answer)?.requests).flatMap((entry) => parseMessageRequest(entry) ?? []);
}

const SOURCES = new Set<ContactSource>(["team", "connection", "agent"]);

export function parseContact(value: unknown): HomeContact | undefined {
  const raw = record(value);
  const id = text(raw?.id);
  const source = text(raw?.source) as ContactSource | undefined;
  if (!raw || !id || !source || !SOURCES.has(source)) return undefined;
  const look = record(raw.look);
  const tag = text(look?.tag);
  const activity = text(look?.activity);
  return {
    id,
    name: text(raw.name) ?? "",
    source,
    ...(tag || activity ? { look: { ...(tag ? { tag } : {}), ...(activity ? { activity } : {}) } } : {}),
  };
}

export const parseContacts = (value: unknown): HomeContact[] =>
  list(value).flatMap((entry) => parseContact(entry) ?? []);

/** `contacts`' answer: the people New Message offers, the team its invite row names, and the
 * invites still pending (the Invite sheet's list; absent from a host without them). */
export function parseContactsAnswer(answer: unknown): {
  contacts: HomeContact[];
  inviteTeam: string | null;
  pendingInvites: string[];
} {
  const raw = record(answer);
  const team = text(raw?.inviteTeam)?.trim();
  return {
    contacts: parseContacts(raw?.contacts),
    inviteTeam: team ? team : null,
    pendingInvites: list(raw?.pendingInvites).flatMap((entry) => (typeof entry === "string" && entry ? [entry] : [])),
  };
}

const ROLES = new Set<MemberRole>(["owner", "admin", "member", "readOnly"]);

function parseMember(value: unknown): GroupMember | undefined {
  const raw = record(value);
  const id = text(raw?.id);
  if (!raw || !id) return undefined;
  const role = text(raw.role) as MemberRole | undefined;
  return {
    id,
    name: text(raw.name) ?? "",
    isMe: flag(raw.isMe),
    isAgent: flag(raw.isAgent),
    isInvited: flag(raw.isInvited),
    ...(role && ROLES.has(role) ? { role } : {}),
  };
}

/** A group's info, or undefined when it has no conversation id. */
export function parseGroupInfo(value: unknown): GroupInfo | undefined {
  const raw = record(value);
  const conversation = text(raw?.conversation);
  if (!raw || !conversation) return undefined;
  const title = text(raw.title) ?? "";
  const replies = text(raw.chiefReplies) as ChiefReplyPolicy | undefined;
  const count = raw.memberCount;
  const info: GroupInfo = {
    conversation,
    isGroup: flag(raw.isGroup),
    title,
    displayTitle: text(raw.displayTitle) ?? title,
    members: list(raw.members).flatMap((entry) => parseMember(entry) ?? []),
    canMute: flag(raw.canMute),
    muted: flag(raw.muted),
  };
  if (typeof count === "number" && Number.isInteger(count) && count >= 0) info.memberCount = count;
  if (replies && CHIEF_REPLY_POLICIES.includes(replies)) info.chiefReplies = replies;
  if (typeof raw.canAddPeople === "boolean") info.canAddPeople = raw.canAddPeople;
  if (typeof raw.canRename === "boolean") info.canRename = raw.canRename;
  return info;
}

/** `group.info`'s answer, or undefined when the host sent no usable info. */
export function parseGroupInfoAnswer(answer: unknown): { info: GroupInfo; addable: HomeContact[] } | undefined {
  const raw = record(answer);
  const info = parseGroupInfo(raw?.info);
  return info ? { info, addable: parseContacts(raw?.addable) } : undefined;
}
