// l10n-allow-file: public sample names in gallery and test fixtures, not shipped copy.
// Sample conversations for the list's gallery entry and tests: public-safe names, times relative
// to the clock given.
import type { HomeConversation, HomeParticipant } from "../../home-channels/types";

export const ME: HomeParticipant = { id: "me", kind: "human", name: "Sam Rivera", chief: false };

const NAMES = [
  "Taylor Brooks",
  "Morgan Lee",
  "Casey Patel",
  "Jordan Kim",
  "Avery Chen",
  "Riley Novak",
  "Quinn Ortiz",
  "Drew Sato",
];
const LINES = [
  "Sounds good, I'll push the fix after lunch.",
  "Can you take a look at the review comments when you get a chance?",
  "The build is green again.",
  "Shipped! Thanks for the quick turnaround on this one.",
  "Let's sync tomorrow morning about the release notes.",
  "I left a note in the doc about the layout question.",
];

function person(index: number): HomeParticipant {
  return { id: `p${index}`, kind: "human", name: NAMES[index % NAMES.length]!, chief: false };
}

export function conversation(partial: Partial<HomeConversation> & { id: string }, now: number): HomeConversation {
  return {
    owner: "local",
    title: "",
    kind: "direct",
    participants: [ME, person(0)],
    lastSeq: 10,
    rev: 1,
    updatedAt: now,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
    lastAt: now,
    lastText: LINES[0],
    ...partial,
  };
}

/** A Home: the Chief and three people pinned, a channel, a group, then `count` DMs going back. */
export function sampleConversations(count: number, now: number): Map<string, HomeConversation> {
  const chief: HomeParticipant = { id: "chief", kind: "agent", name: "Chief", chief: true };
  const list: HomeConversation[] = [
    conversation(
      {
        id: "c-chief",
        kind: "chief",
        participants: [ME, chief],
        pinned: true,
        pinPosition: 1,
        lastText: "Done: the release checklist is up to date.",
        lastAuthor: "chief",
        lastAt: now - 4 * 60_000,
      },
      now,
    ),
    conversation(
      {
        id: "c-taylor",
        participants: [ME, person(0)],
        pinned: true,
        pinPosition: 2,
        unread: 2,
        lastAt: now - 20 * 60_000,
      },
      now,
    ),
    conversation(
      {
        id: "c-morgan",
        participants: [ME, person(1)],
        pinned: true,
        pinPosition: 3,
        lastText: LINES[2],
        lastAt: now - 3 * 3_600_000,
      },
      now,
    ),
    conversation(
      {
        id: "c-casey",
        participants: [ME, person(2)],
        pinned: true,
        pinPosition: 4,
        markedUnread: true,
        lastText: LINES[3],
        lastAt: now - 26 * 3_600_000,
      },
      now,
    ),
    conversation(
      {
        id: "c-design",
        title: "design",
        kind: "group",
        participants: [ME, person(3), person(4), chief],
        unread: 5,
        mentions: 1,
        lastText: LINES[1],
        lastAuthor: "p3",
        lastAt: now - 40 * 60_000,
      },
      now,
    ),
    conversation(
      {
        id: "c-trip",
        title: "Weekend trip",
        kind: "group",
        participants: [ME, person(5), person(6), person(7)],
        lastText: LINES[4],
        lastAt: now - 2 * 86_400_000,
      },
      now,
    ),
  ];
  for (let index = 0; index < count; index++) {
    list.push(
      conversation(
        {
          id: `c-dm-${index}`,
          title: `${NAMES[index % NAMES.length]} ${index + 1}`,
          participants: [ME, { ...person(index), id: `p-dm-${index}` }],
          unread: index % 7 === 0 ? 1 : 0,
          muted: index % 11 === 5,
          lastText: LINES[index % LINES.length],
          lastAt: now - (index + 3) * 7 * 3_600_000,
        },
        now,
      ),
    );
  }
  return new Map(list.map((c) => [c.id, c]));
}
