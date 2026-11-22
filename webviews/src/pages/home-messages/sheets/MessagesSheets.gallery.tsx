// l10n-allow-file: gallery fixtures (public sample people and teams), not shipped copy.
import { useMemo, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { createStrings } from "../../shared/i18n";
import table from "./generated/strings.json";
import type { ComposeActions, GroupInfoActions, RequestsActions } from "./actions";
import { parseAddress } from "./address";
import { GroupInfoSheet } from "./GroupInfoSheet";
import { InviteSheet, TeamInviteSheet } from "./InviteSheets";
import { chiefTag, type GroupInfo, type GroupOutcome, type MessageRequest, type SeatImpact } from "./model";
import { NewChiefSheet } from "./NewChiefSheet";
import { NewMessage } from "./NewMessage";
import type { TokenStyle } from "./RecipientField";
import {
  EMPTY_DRAFT,
  addressRecipient,
  contactRecipient,
  type HomeContact,
  type HomeRecipient,
  type RecipientDraft,
} from "./recipients";
import { RequestsSheet } from "./RequestsSheet";

type Sheet = "requests" | "group" | "chief" | "invite" | "team" | "new-message";
type Props = {
  sheet: Sheet;
  /** Actions answer with a refusal (the error state). */
  failing?: boolean;
  /** Actions never answer (the running state). */
  pending?: boolean;
  requests?: MessageRequest[];
  info?: GroupInfo;
  adding?: boolean;
  impact?: SeatImpact | "checking";
  agent?: boolean;
  backend?: string;
  name?: string;
  prefill?: string;
  draft?: RecipientDraft;
  existing?: boolean;
  tokenStyle?: TokenStyle;
  notice?: boolean;
};

const never = <T,>() => new Promise<T>(() => {});

const contacts: HomeContact[] = [
  { id: "chief-main", name: "Chief", source: "agent" },
  { id: "chief-mac", name: "Chief", source: "agent" },
  { id: "chief-research", name: "Research", source: "agent" },
  { id: "p-ada", name: "Ada Park", source: "team" },
  { id: "p-ben", name: "Ben Ito", source: "team" },
  { id: "p-cleo", name: "Cleo Diaz", source: "team" },
  { id: "p-dev", name: "Devi Rao", source: "team" },
  { id: "p-eli", name: "Eli Moss", source: "connection" },
];

const requests: MessageRequest[] = [
  {
    conversation: "c-req-1",
    inviter: "Morgan Lee",
    isGroup: false,
    preview: "Hi! We met at the meetup last week. Do you have a minute to look at the deploy script?",
    trusted: true,
  },
  {
    conversation: "c-req-2",
    inviter: "Sam Kerr",
    isGroup: true,
    title: "Launch planning",
    preview: "",
    trusted: false,
  },
  {
    conversation: "c-req-3",
    inviter: "Jo Tan",
    isGroup: true,
    preview: "Adding you to the review rota.",
    trusted: false,
  },
];

const groupInfo: GroupInfo = {
  conversation: "c-group",
  isGroup: true,
  title: "Launch crew",
  displayTitle: "Launch crew",
  members: [
    { id: "me", name: "Taylor Fox", isMe: true, isAgent: false, isInvited: false, role: "owner" },
    { id: "p-ada", name: "Ada Park", isMe: false, isAgent: false, isInvited: false, role: "admin" },
    { id: "chief-main", name: "Chief", isMe: false, isAgent: true, isInvited: false },
    { id: "p-ben", name: "Ben Ito", isMe: false, isAgent: false, isInvited: false, role: "readOnly" },
    { id: "invite-1", name: "riley@example.com", isMe: false, isAgent: false, isInvited: true },
  ],
  canMute: true,
  muted: false,
  chiefReplies: "auto",
};

const dmInfo: GroupInfo = {
  conversation: "c-dm",
  isGroup: false,
  title: "",
  displayTitle: "Ada Park",
  members: [
    { id: "me", name: "Taylor Fox", isMe: true, isAgent: false, isInvited: false },
    { id: "p-ada", name: "Ada Park", isMe: false, isAgent: false, isInvited: false },
  ],
  canMute: true,
  muted: true,
};

const largeInfo: GroupInfo = {
  ...groupInfo,
  title: "Everyone",
  displayTitle: "Everyone",
  memberCount: 5000,
  chiefReplies: "mentions",
  members: Array.from({ length: 5000 }, (_, index) => ({
    id: `m-${index}`,
    name: index === 0 ? "Taylor Fox" : `Member ${index}`,
    isMe: index === 0,
    isAgent: false,
    isInvited: false,
  })),
};

function SheetsDemo(props: Props) {
  const [strings] = useState(() => createStrings(table));
  const [draft, setDraft] = useState<RecipientDraft>(props.draft ?? EMPTY_DRAFT);
  const outcome = (): Promise<GroupOutcome> =>
    props.pending
      ? never()
      : Promise.resolve(props.failing ? { kind: "notReachable", name: "Eli Moss" } : { kind: "done" });
  const group = useMemo<GroupInfoActions>(
    () => ({
      rename: outcome,
      add: outcome,
      remove: outcome,
      setMuted: outcome,
      setChiefReplies: outcome,
      leave: () => {},
      inviteByEmail: () => {},
    }),
    // oxlint-disable-next-line react-hooks/exhaustive-deps
    [],
  );
  const answers = useMemo<RequestsActions>(
    () => ({ answer: () => (props.pending ? never() : Promise.resolve(!props.failing)) }),
    // oxlint-disable-next-line react-hooks/exhaustive-deps
    [],
  );
  const compose = useMemo<ComposeActions>(
    () => ({
      createChief: () => (props.pending ? never() : Promise.resolve({ kind: "offline" })),
      invite: () => (props.pending ? never() : Promise.resolve({ kind: "refused", reason: "" })),
      seatImpact: () => (!props.impact || props.impact === "checking" ? never() : Promise.resolve(props.impact)),
      inviteToTeam: () => Promise.resolve({ kind: "refused", reason: "riley@example.com is already in the team." }),
      start: () => Promise.resolve({ kind: "rateLimited" }),
      newChief: () => {},
      openInvite: () => {},
      openTeamInvite: () => {},
    }),
    // oxlint-disable-next-line react-hooks/exhaustive-deps
    [],
  );
  const done = () => {};
  const look = (recipient: HomeRecipient) => {
    if (recipient.kind !== "contact") return {};
    if (recipient.contact.id === "chief-main")
      return {
        tag: chiefTag({ main: true, place: { kind: "cloud" } }, strings),
        activity: strings.format("home.compose.activeAgo", "2 minutes ago"),
      };
    if (recipient.contact.id === "chief-mac")
      return {
        tag: chiefTag({ main: false, place: { kind: "thisMac" } }, strings),
        activity: strings.format("home.compose.activeAgo", "yesterday"),
      };
    return {};
  };
  switch (props.sheet) {
    case "requests":
      return <RequestsSheet strings={strings} requests={props.requests ?? []} actions={answers} onFinish={done} />;
    case "group":
      return (
        <GroupInfoSheet
          strings={strings}
          info={props.info ?? groupInfo}
          addable={contacts.filter((contact) => contact.source !== "agent")}
          actions={group}
          onClose={done}
          initialAdding={props.adding}
        />
      );
    case "chief":
      return (
        <NewChiefSheet
          strings={strings}
          actions={compose}
          onFinish={done}
          initialName={props.name}
          initialBackend={props.backend}
        />
      );
    case "invite":
      return (
        <InviteSheet
          strings={strings}
          actions={compose}
          pending={props.failing ? [] : ["riley@example.com", "sam@example.org"]}
          prefill={props.prefill}
          onFinish={done}
        />
      );
    case "team":
      return (
        <TeamInviteSheet
          strings={strings}
          actions={compose}
          team="Acme"
          prefill={props.prefill}
          requestedByAgent={props.agent}
          onFinish={done}
        />
      );
    case "new-message":
      return (
        <div style={{ height: "100%" }}>
          <NewMessage
            strings={strings}
            draft={draft}
            onDraft={setDraft}
            contacts={contacts}
            rows={
              props.existing ? [{ id: "c-ada", kind: "direct", participants: [{ id: "me" }, { id: "p-ada" }] }] : []
            }
            me="me"
            actions={compose}
            inviteTeam="Acme"
            look={look}
            onSent={done}
            onEscape={done}
            onFocusMessage={done}
            tokenStyle={props.tokenStyle}
            initialNotice={props.notice ? strings.t("home.outcome.rateLimited") : undefined}
            renderConversation={(id) => <p className="hm-sheet-caption">{`Conversation ${id}`}</p>}
            renderComposer={() => <p className="hm-sheet-caption">{strings.t("home.compose.title")}</p>}
          />
        </div>
      );
  }
}

const ada = contacts[3]!;
const mixed: RecipientDraft = {
  tokens: [
    { text: ada.name, recipient: contactRecipient(ada) },
    { text: "Chief", recipient: contactRecipient(contacts[0]!) },
    { text: "riley@example.com", recipient: addressRecipient(parseAddress("riley@example.com")!) },
    { text: "Quinn", recipient: null },
  ],
  query: "",
};

export default componentEntry<Props>({
  id: "home.messages-sheets",
  title: "Messages sheets and New Message",
  area: "Home and Chief",
  height: 640,
  covers: [
    "pages/home-messages/sheets/RequestsSheet.tsx#RequestsSheet",
    "pages/home-messages/sheets/GroupInfoSheet.tsx#GroupInfoSheet",
    "pages/home-messages/sheets/NewChiefSheet.tsx#NewChiefSheet",
    "pages/home-messages/sheets/InviteSheets.tsx#InviteSheet",
    "pages/home-messages/sheets/InviteSheets.tsx#TeamInviteSheet",
    "pages/home-messages/sheets/NewMessage.tsx#NewMessage",
    "pages/home-messages/sheets/RecipientField.tsx#RecipientField",
    "pages/home-messages/sheets/SheetFrame.tsx#SheetFrame",
  ],
  load: async () => SheetsDemo,
  styles: () =>
    Promise.all([
      import("../../home-channels/styles.css"),
      import("../../home-channels/ledger.css"),
      import("./sheets.css"),
    ]),
  variants: {
    "requests-full": {
      note: "Three requests: a trusted DM, a titled group, an untitled group.",
      props: { sheet: "requests", requests },
    },
    "requests-empty": { props: { sheet: "requests", requests: [] } },
    "requests-error": {
      note: "Accept was refused: the request stays and the status line says so.",
      props: { sheet: "requests", requests, failing: true },
      play: async (ctx) => ctx.click({ testId: "cmux.home.requests.accept.c-req-1" }),
    },
    "group-full": { props: { sheet: "group", info: groupInfo } },
    "group-dm": { props: { sheet: "group", info: dmInfo } },
    "group-adding": { props: { sheet: "group", info: groupInfo, adding: true } },
    "group-large": {
      note: "5,000 members: the list draws only what shows.",
      props: { sheet: "group", info: largeInfo },
    },
    "group-error": {
      note: "Rename refused as not reachable: Invite by Email… shows.",
      props: { sheet: "group", info: { ...groupInfo, title: "" }, failing: true },
      play: async (ctx) => ctx.click({ testId: "cmux.home.groupInfo.rename" }),
    },
    "chief-empty": { props: { sheet: "chief" } },
    "chief-codex": {
      note: "Codex chosen: its note shows.",
      props: { sheet: "chief", name: "Builder", backend: "codex" },
    },
    "chief-loading": {
      props: { sheet: "chief", name: "Builder", pending: true },
      play: async (ctx) => ctx.click({ testId: "cmux.home.sheet.primary" }),
    },
    "chief-error": {
      props: { sheet: "chief", name: "Builder", backend: "unii" },
      play: async (ctx) => ctx.click({ testId: "cmux.home.sheet.primary" }),
    },
    "invite-full": { props: { sheet: "invite", prefill: "riley@example.com" } },
    "invite-empty": { props: { sheet: "invite", failing: true } },
    "invite-error": {
      props: { sheet: "invite", prefill: "riley@" },
      play: async (ctx) => ctx.click({ testId: "cmux.home.sheet.primary" }),
    },
    "team-checking": {
      note: "The plan is being read: Send waits.",
      props: { sheet: "team", impact: "checking", prefill: "riley@example.com" },
    },
    "team-paid": { props: { sheet: "team", impact: { kind: "paidSeat", members: 12 }, prefill: "riley@example.com" } },
    "team-capped-agent": {
      note: "An agent asked: a line asks the person to check the address.",
      props: {
        sheet: "team",
        impact: { kind: "capped", members: 4, limit: 5 },
        prefill: "riley@example.com",
        agent: true,
      },
    },
    "team-not-allowed": { props: { sheet: "team", impact: { kind: "notAllowed" }, prefill: "riley@example.com" } },
    "team-error": {
      props: { sheet: "team", impact: { kind: "free", members: 3 }, prefill: "riley@example.com" },
      play: async (ctx) => ctx.click({ testId: "cmux.home.sheet.primary" }),
    },
    "new-message-idle": {
      note: "Nothing typed: the Chiefs, New Chief, then the team.",
      props: { sheet: "new-message" },
    },
    "new-message-typed": {
      note: "Typing suggests people; the email row is followed by Invite to Acme.",
      props: { sheet: "new-message", draft: { tokens: [], query: "a" } },
    },
    "new-message-email": { props: { sheet: "new-message", draft: { tokens: [], query: "riley@example.com" } } },
    "new-message-mixed": {
      note: "A person, a Chief, an address and a red token (pill tokens, the pick).",
      props: { sheet: "new-message", draft: mixed, notice: true },
    },
    "new-message-mixed-outline": { props: { sheet: "new-message", draft: mixed, tokenStyle: "outline" } },
    "new-message-mixed-text": { props: { sheet: "new-message", draft: mixed, tokenStyle: "text" } },
    "new-message-existing": {
      note: "Ada already has a DM: it shows under the field.",
      props: {
        sheet: "new-message",
        draft: { tokens: [{ text: ada.name, recipient: contactRecipient(ada) }], query: "" },
        existing: true,
      },
    },
  },
});
