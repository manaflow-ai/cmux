// New Message's To: rules (HomeNewMessageDraft): typed text becomes tokens, Backspace deletes
// them, the list under the field suggests people, and one draft mixes people, Chiefs, addresses
// and red tokens.
import { describe, expect, test } from "bun:test";
import { createStrings } from "../../shared/i18n";
import { parseAddress } from "./address";
import {
  EMPTY_DRAFT,
  addRecipient,
  chiefShortcuts,
  commitDraft,
  contactRecipient,
  deleteBackward,
  draftRecipients,
  existingConversation,
  hasInvalidTokens,
  idleRows,
  idleSuggestions,
  isGroupDraft,
  removeToken,
  resolveRecipient,
  sendBlocker,
  suggestRecipients,
  suggestionLines,
  typedRows,
  type HomeContact,
  type RecipientDraft,
} from "./recipients";

const strings = createStrings(
  {
    en: {
      "home.compose.unknownRecipient": "No one named “%@”. Type their email address to invite them.",
      "home.compose.needsRecipient": "Add someone in To: first.",
      "home.list.section.chiefs": "Chiefs",
      "home.compose.section.team": "Team",
      "home.compose.source.team": "Team",
      "home.compose.source.agent": "Chief",
      "home.compose.source.connection": "Contact",
      "home.compose.address.email": "Email",
      "home.compose.address.phone": "Phone",
    },
  },
  ["en"],
);

const contacts: HomeContact[] = [
  { id: "chief-1", name: "Chief", source: "agent" },
  { id: "chief-2", name: "Chief", source: "agent" },
  { id: "p-ada", name: "Ada Park", source: "team" },
  { id: "p-adam", name: "Adam Ito", source: "team" },
  { id: "p-zoe", name: "Zoë Lin", source: "team" },
  { id: "p-eli", name: "Eli Shade", source: "connection" },
];
const typed = (query: string, draft: RecipientDraft = EMPTY_DRAFT): RecipientDraft => ({ ...draft, query });
const texts = (draft: RecipientDraft) => draft.tokens.map((token) => [token.text, token.recipient !== null]);

describe("tokenizing", () => {
  test("an exact name, an id and an address each become a token", () => {
    let draft = commitDraft(typed("ada park"), contacts).draft;
    draft = commitDraft(typed("p-zoe", draft), contacts).draft;
    draft = commitDraft(typed("  Riley@Example.COM, ", draft), contacts).draft;
    expect(texts(draft)).toEqual([
      ["Ada Park", true],
      ["Zoë Lin", true],
      ["riley@example.com", true],
    ]);
    expect(draft.query).toBe("");
  });

  test("a unique prefix resolves, diacritics and case ignored; an ambiguous one does not", () => {
    expect(resolveRecipient("zoe", contacts)).toEqual(contactRecipient(contacts[4]!));
    expect(resolveRecipient("Ad", contacts)).toBeNull();
    expect(resolveRecipient("eli", contacts)).toEqual(contactRecipient(contacts[5]!));
  });

  test("text that names nobody becomes a red token that blocks the send", () => {
    const draft = commitDraft(typed("Quinn"), contacts).draft;
    expect(texts(draft)).toEqual([["Quinn", false]]);
    expect(hasInvalidTokens(draft)).toBe(true);
    expect(sendBlocker(draft, strings)).toBe("No one named “Quinn”. Type their email address to invite them.");
  });

  test("nothing typed commits nothing; a recipient already chosen is added once", () => {
    expect(commitDraft(typed(" ,; "), contacts).committed).toBe(false);
    const once = addRecipient(EMPTY_DRAFT, contactRecipient(contacts[2]!));
    const twice = commitDraft(typed("Ada Park", once), contacts);
    expect(twice.committed).toBe(true);
    expect(twice.draft.tokens).toHaveLength(1);
  });

  test("addresses normalize: a US number gains its country code, bad ones refuse", () => {
    expect(parseAddress("(415) 555-0134")).toEqual({ kind: "phone", value: "+14155550134" });
    expect(parseAddress("0044 20 7946 0958")).toEqual({ kind: "phone", value: "+442079460958" });
    for (const bad of ["a@b", "@x.com", "a@x..com", ".a@x.com", "555-0134", "4+15", "hello"])
      expect(parseAddress(bad)).toBeNull();
  });
});

describe("deleting", () => {
  test("Backspace with nothing typed removes the last token; with text typed it does not", () => {
    const draft = addRecipient(
      addRecipient(EMPTY_DRAFT, contactRecipient(contacts[2]!)),
      contactRecipient(contacts[4]!),
    );
    expect(texts(deleteBackward(draft)!)).toEqual([["Ada Park", true]]);
    expect(deleteBackward({ ...draft, query: "x" })).toBeNull();
    expect(deleteBackward(EMPTY_DRAFT)).toBeNull();
  });

  test("a chosen token is removed by its index", () => {
    const draft = commitDraft(
      typed("Quinn", addRecipient(EMPTY_DRAFT, contactRecipient(contacts[2]!))),
      contacts,
    ).draft;
    expect(texts(removeToken(draft, 1))).toEqual([["Ada Park", true]]);
    expect(removeToken(draft, 5)).toBe(draft);
  });
});

describe("suggestions", () => {
  test("a typed address leads, then word starts, then names containing the text", () => {
    const names = (draft: RecipientDraft) =>
      suggestRecipients(draft, contacts).map((recipient) =>
        recipient.kind === "contact" ? recipient.contact.name : recipient.address.value,
      );
    expect(names(typed("ad"))).toEqual(["Ada Park", "Adam Ito", "Eli Shade"]);
    expect(names(typed("lin"))).toEqual(["Zoë Lin"]);
    expect(names(typed("riley@example.com"))).toEqual(["riley@example.com"]);
    expect(names(typed(""))).toEqual([]);
    expect(names(typed("ad", addRecipient(EMPTY_DRAFT, contactRecipient(contacts[2]!))))).toEqual([
      "Adam Ito",
      "Eli Shade",
    ]);
  });

  test("the idle list has the Chiefs and New Chief, then the team; Invite when the team is empty", () => {
    const offered = idleSuggestions(EMPTY_DRAFT, contacts);
    expect(offered.map((contact) => contact.id)).toEqual(["chief-1", "chief-2", "p-ada", "p-adam", "p-zoe"]);
    expect(idleRows(offered, { newChief: true, invite: true }, strings).map((row) => row.kind)).toEqual([
      "header",
      "recipient",
      "recipient",
      "newChief",
      "header",
      "recipient",
      "recipient",
      "recipient",
    ]);
    expect(idleRows([], { newChief: false, invite: true }, strings)).toEqual([
      { kind: "header", title: "Team" },
      { kind: "invite" },
    ]);
  });

  test("a typed email gets an Invite to <team> row right after it, only with a team", () => {
    const rows = typedRows(typed("riley@example.com"), contacts, "Acme");
    expect(rows.map((row) => row.kind)).toEqual(["recipient", "inviteToTeam"]);
    expect(typedRows(typed("riley@example.com"), contacts, null).map((row) => row.kind)).toEqual(["recipient"]);
    expect(typedRows(typed("4155550134"), contacts, "Acme").map((row) => row.kind)).toEqual(["recipient"]);
  });

  test("two rows that read alike gain when they were last active, then a number", () => {
    const rows = idleRows(contacts.slice(0, 2), { newChief: false, invite: false }, strings);
    const active = suggestionLines(
      rows,
      (recipient) => ({
        activity: recipient.kind === "contact" && recipient.contact.id === "chief-1" ? "Active now" : "Active today",
      }),
      strings,
    );
    expect([active.get(1), active.get(2)]).toEqual(["Chief · Active now", "Chief · Active today"]);
    const same = suggestionLines(rows, () => ({ tag: "This Mac" }), strings);
    expect([same.get(1), same.get(2)]).toEqual(["Chief · This Mac", "Chief · This Mac · 2"]);
  });
});

describe("mixed recipients", () => {
  const riley = parseAddress("riley@example.com")!;
  const mixed = [addRecipient, addRecipient].reduce(
    (draft, add, index) => add(draft, index === 0 ? contactRecipient(contacts[2]!) : contactRecipient(contacts[0]!)),
    commitDraft(typed("riley@example.com"), contacts).draft,
  );

  test("people, Chiefs and addresses mix in one group draft, in the order added", () => {
    expect(texts(mixed)).toEqual([
      ["riley@example.com", true],
      ["Ada Park", true],
      ["Chief", true],
    ]);
    expect(isGroupDraft(mixed)).toBe(true);
    expect(draftRecipients(mixed).map((recipient) => recipient.kind)).toEqual(["address", "contact", "contact"]);
    expect(sendBlocker(mixed, strings)).toBeNull();
  });

  test("the group with exactly them is found, an invited address matching its person", () => {
    const rows = [
      { id: "dm-ada", kind: "direct" as const, participants: [{ id: "me" }, { id: "p-ada" }] },
      {
        id: "group-1",
        kind: "group" as const,
        participants: [{ id: "me" }, { id: "p-ada" }, { id: "chief-1" }, { id: "x-1", invited: riley.value }],
      },
    ];
    expect(existingConversation(mixed, rows, "me")).toBe("group-1");
    const ada = addRecipient(EMPTY_DRAFT, contactRecipient(contacts[2]!));
    expect(existingConversation(ada, rows, "me")).toBe("dm-ada");
    const red = commitDraft(typed("Quinn", mixed), contacts).draft;
    expect(existingConversation(red, rows, "me")).toBeNull();
  });

  test("an empty draft says to add someone first", () => {
    expect(sendBlocker(EMPTY_DRAFT, strings)).toBe("Add someone in To: first.");
  });
});

// The cases the native New Message's tests held (HomeNewMessageTests, deleted with it in #37736).
describe("Chiefs in New Message", () => {
  const chiefs: HomeContact[] = Array.from({ length: 8 }, (_, index) => ({
    id: `chief-${index + 1}`,
    name: `Chief ${index + 1}`,
    source: "agent",
  }));

  test("before anything is typed at most six Chiefs are listed, the chosen ones left out", () => {
    expect(chiefShortcuts(EMPTY_DRAFT, chiefs).map((chief) => chief.id)).toEqual([
      "chief-1",
      "chief-2",
      "chief-3",
      "chief-4",
      "chief-5",
      "chief-6",
    ]);
    const one = addRecipient(EMPTY_DRAFT, contactRecipient(chiefs[0]!));
    expect(chiefShortcuts(one, chiefs).map((chief) => chief.id)).toEqual([
      "chief-2",
      "chief-3",
      "chief-4",
      "chief-5",
      "chief-6",
      "chief-7",
    ]);
    // The team follows the capped Chiefs, never squeezed out by them.
    const team: HomeContact = { id: "p-ada", name: "Ada Park", source: "team" };
    expect(idleSuggestions(EMPTY_DRAFT, [...chiefs, team]).map((contact) => contact.id)).toHaveLength(7);
    expect(idleSuggestions(EMPTY_DRAFT, [...chiefs, team]).at(-1)?.id).toBe("p-ada");
  });

  test("one Chief opens its own conversation; two Chiefs make a group, the one with exactly them", () => {
    const rows = [
      { id: "chief-1-chat", kind: "chief" as const, participants: [{ id: "me" }, { id: "chief-1" }] },
      { id: "chief-2-chat", kind: "chief" as const, participants: [{ id: "me" }, { id: "chief-2" }] },
      {
        id: "three",
        kind: "group" as const,
        participants: [{ id: "me" }, { id: "chief-1" }, { id: "chief-2" }, { id: "p-ada" }],
      },
      { id: "both", kind: "group" as const, participants: [{ id: "me" }, { id: "chief-1" }, { id: "chief-2" }] },
    ];
    const one = addRecipient(EMPTY_DRAFT, contactRecipient(chiefs[0]!));
    expect(isGroupDraft(one)).toBe(false);
    expect(existingConversation(one, rows, "me")).toBe("chief-1-chat");
    const two = addRecipient(one, contactRecipient(chiefs[1]!));
    expect(isGroupDraft(two)).toBe(true);
    expect(existingConversation(two, rows, "me")).toBe("both");
    // No group with exactly them yet: the page is blank and the first send makes it.
    expect(existingConversation(two, rows.slice(0, 3), "me")).toBeNull();
  });

  test("one person shows their DM, several the group with exactly them, and nobody's DM a blank page", () => {
    const people = contacts.slice(2, 5);
    const rows = [
      { id: "group-big", kind: "group" as const, participants: [{ id: "me" }, ...people.map(({ id }) => ({ id }))] },
      { id: "dm-ada", kind: "direct" as const, participants: [{ id: "me" }, { id: "p-ada" }] },
      { id: "group-two", kind: "group" as const, participants: [{ id: "me" }, { id: "p-ada" }, { id: "p-adam" }] },
    ];
    let draft = addRecipient(EMPTY_DRAFT, contactRecipient(people[0]!));
    expect(existingConversation(draft, rows, "me")).toBe("dm-ada");
    draft = addRecipient(draft, contactRecipient(people[1]!));
    expect(existingConversation(draft, rows, "me")).toBe("group-two");
    draft = addRecipient(draft, contactRecipient(people[2]!));
    expect(existingConversation(draft, rows, "me")).toBe("group-big");
    expect(existingConversation(addRecipient(EMPTY_DRAFT, contactRecipient(people[2]!)), rows, "me")).toBeNull();
  });
});
