// What the Messages sheets do, and the one path each takes. The sheets hold no store: each control
// runs one of these, and the host bridge runs the same Swift code the AppKit sheet ran
// (TopHomePageView.present*, HomeGroupInfoActions, HomeTeamInviteRun), or the catalog action the
// palette and CLI run (`cmux.app.action.run`). Nothing here talks to an owner on its own.
//
// Host ops (`cmux.home.messages.*`, the page's PageRoute; each answers the shapes in model.ts):
//   requests.answer      {conversation, answer}      -> {ok}          HomeMessageRequests.answer
//   group.rename         {conversation, title}       -> {outcome}     HomeGroupActions.rename
//   group.add            {conversation, people, names} -> {outcome}   HomeGroupActions.add
//   group.remove         {conversation, participant} -> {outcome}     HomeGroupActions.remove
//   group.mute           {conversation, muted}       -> {outcome}     HomeGroupActions.setMuted
//   group.chiefReplies   {conversation, replies}     -> {outcome}     HomeGroupActions.setChiefReplies
//   chief.create         {name, backend}             -> {outcome}     HomeService.createChief
//   invite.send          {email}                     -> {outcome}     HomeService.invite
//   teamInvite.seatImpact {}                         -> {impact}      HomeTeamInviteRun.seatImpact
//   teamInvite.send      {email}                     -> {result}      HomeTeamInviteRun.invite
//   start                {recipients, text}          -> {outcome}     HomeService.startConversation
//                                                                     (+ the first message's send)
// Catalog actions (the PageDescriptor's allowed actions): home.leaveConversation (asks first),
// home.invite, home.inviteToTeam {email}, home.newChief.
import { isPageError, type PageClient } from "../../shared/pageClient";
import type { Strings } from "../../shared/i18n";
import type { ContactAddress } from "./address";
import {
  teamInviteOutcome,
  type ChiefReplyPolicy,
  type ComposeOutcome,
  type GroupOutcome,
  type RequestAnswer,
  type SeatImpact,
  type TeamInviteResult,
} from "./model";
import type { HomeRecipient } from "./recipients";

export const MessagesSheetOps = {
  requestsAnswer: "cmux.home.messages.requests.answer",
  groupRename: "cmux.home.messages.group.rename",
  groupAdd: "cmux.home.messages.group.add",
  groupRemove: "cmux.home.messages.group.remove",
  groupMute: "cmux.home.messages.group.mute",
  groupChiefReplies: "cmux.home.messages.group.chiefReplies",
  chiefCreate: "cmux.home.messages.chief.create",
  inviteSend: "cmux.home.messages.invite.send",
  teamSeatImpact: "cmux.home.messages.teamInvite.seatImpact",
  teamInviteSend: "cmux.home.messages.teamInvite.send",
  start: "cmux.home.messages.start",
} as const;

/** The shared host op that runs a catalog action. */
export const ACTION_RUN = "cmux.app.action.run";

/** The catalog actions the sheets run (the page's PageDescriptor must allow them). */
export const MessagesSheetActions = {
  leave: "home.leaveConversation",
  invite: "home.invite",
  inviteToTeam: "home.inviteToTeam",
  newChief: "home.newChief",
} as const;

export interface RequestsActions {
  /** Accept, Decline or Block; false keeps the request and says it failed. */
  answer(conversation: string, answer: RequestAnswer): Promise<boolean>;
}

export interface GroupInfoActions {
  rename(title: string): Promise<GroupOutcome>;
  /** Add these people (ids, and their names for a refusal). */
  add(people: readonly string[], names: string): Promise<GroupOutcome>;
  remove(participant: string): Promise<GroupOutcome>;
  setMuted(muted: boolean): Promise<GroupOutcome>;
  setChiefReplies(policy: ChiefReplyPolicy): Promise<GroupOutcome>;
  /** Leave Group…: the sheet has closed; the action asks, then leaves. */
  leave(): void;
  /** Invite by Email… after a `not_reachable` refusal: the sheet has closed. */
  inviteByEmail(): void;
}

export interface ComposeActions {
  createChief(name: string, backend: string): Promise<ComposeOutcome>;
  invite(address: ContactAddress): Promise<ComposeOutcome>;
  seatImpact(): Promise<SeatImpact>;
  inviteToTeam(address: ContactAddress): Promise<ComposeOutcome>;
  /** New Message's first send: makes the DM or group with `recipients` and posts `text` there. */
  start(recipients: readonly HomeRecipient[], text: string): Promise<ComposeOutcome>;
  /** The To: list's New Chief row (`home.newChief`). */
  newChief(): void;
  /** The To: list's Invite row (`home.invite`). */
  openInvite(): void;
  /** The To: list's "Invite … to <team>" row (`home.inviteToTeam`, its dialog, prefilled). */
  openTeamInvite(address: ContactAddress): void;
}

/** A refusal the host sent as an error, as the sheet's status line reads it. */
function refused(error: unknown): { kind: "refused"; reason: string } {
  return { kind: "refused", reason: isPageError(error) || error instanceof Error ? error.message : "" };
}

const wireRecipient = (recipient: HomeRecipient) =>
  recipient.kind === "contact"
    ? { contact: recipient.contact.id }
    : { address: recipient.address.value, addressKind: recipient.address.kind };

/** The actions over the page's host. */
export function hostActions(host: PageClient, strings: Strings) {
  const outcome = async <T>(op: string, params: Record<string, unknown>, fallback: (error: unknown) => T) => {
    try {
      const answer = await host.call<{ outcome: T }>(op, params);
      return answer.outcome;
    } catch (error) {
      return fallback(error);
    }
  };
  const action = (id: string, args: Record<string, unknown> = {}) =>
    void host.call(ACTION_RUN, { action: id, args }).catch(() => undefined);
  const group = (conversation: string): GroupInfoActions => ({
    rename: (title) => outcome(MessagesSheetOps.groupRename, { conversation, title }, refused),
    add: (people, names) => outcome(MessagesSheetOps.groupAdd, { conversation, people, names }, refused),
    remove: (participant) => outcome(MessagesSheetOps.groupRemove, { conversation, participant }, refused),
    setMuted: (muted) => outcome(MessagesSheetOps.groupMute, { conversation, muted }, refused),
    setChiefReplies: (replies) => outcome(MessagesSheetOps.groupChiefReplies, { conversation, replies }, refused),
    leave: () => action(MessagesSheetActions.leave, { conversation }),
    inviteByEmail: () => action(MessagesSheetActions.invite),
  });
  const requests: RequestsActions = {
    answer: (conversation, answer) =>
      host.call<{ ok: boolean }>(MessagesSheetOps.requestsAnswer, { conversation, answer }).then(
        (reply) => reply.ok === true,
        () => false,
      ),
  };
  const compose: ComposeActions = {
    createChief: (name, backend) => outcome(MessagesSheetOps.chiefCreate, { name, backend }, refused),
    invite: (address) => outcome(MessagesSheetOps.inviteSend, { email: address.value }, refused),
    seatImpact: () =>
      host.call<{ impact: SeatImpact }>(MessagesSheetOps.teamSeatImpact, {}).then(
        (reply) => reply.impact,
        (): SeatImpact => ({ kind: "unknown" }),
      ),
    inviteToTeam: async (address) => {
      const result = await host
        .call<{ result: TeamInviteResult }>(MessagesSheetOps.teamInviteSend, { email: address.value })
        .then(
          (reply) => reply.result,
          (): TeamInviteResult => ({ kind: "unreachable" }),
        );
      return teamInviteOutcome(result, address.value, strings);
    },
    start: (recipients, text) =>
      outcome(MessagesSheetOps.start, { recipients: recipients.map(wireRecipient), text }, refused),
    newChief: () => action(MessagesSheetActions.newChief),
    openInvite: () => action(MessagesSheetActions.invite),
    openTeamInvite: (address) => action(MessagesSheetActions.inviteToTeam, { email: address.value }),
  };
  return { requests, group, compose };
}
