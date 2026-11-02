// l10n-allow-file: gallery fixtures (made-up people, prompts and replies), not shipped UI.
// A guest's message waits for the owner (design/chat-multiplayer.md, "Held message card"). Leo,
// 2026-10-28, on Theo's T3 Code "Share with guest": "we want to be having, be able to do this kind
// of flow for CMux multiplayer ... we can work on the agent chat multiplayer." In that flow "each
// message they send waits for you": the owner approves each one. Approve sends it to the agent,
// Decline drops it to one quiet line. The held card's look: A (`inline`, the pick) has Approve and
// Decline in the line's action area before "Waiting for you"; B (`bar`) puts them in a bar under
// the message; C (`menu`) keeps the label and puts them in a ⋯ menu, Approve first.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";
import { QUEUED_MESSAGE, type AcpmuxRow, type AcpmuxSnapshot, type QueuedPrompt } from "../model";
import type { Participant } from "./participants";
import { ANA } from "./people.fixtures";

const CY: Participant = { id: "guest:sh-7k2m.g-1", name: "Cy Park" };
const DEV: Participant = { id: "guest:sh-7k2m.g-2", name: "Dev Rao" };

const done = (): AcpmuxRow[] => [
  user("Add retry with backoff to the uploader", 14, { seq: 1 }),
  assistant("Done: three tries, doubling from 200 ms, only on 5xx and timeouts.", 13),
  summary(13, { seq: 3, status: "completed" }),
];
const working = (): AcpmuxRow[] => [
  ...done(),
  user("Cover it with a test that fakes two timeouts", 2, { seq: 4 }),
  assistant("Writing `uploader.retry.test.ts`…", 1, { streaming: true }),
];

const held = (id: string, by: Participant, prompt: string): QueuedPrompt => ({
  id,
  prompt,
  author: by,
  awaitingOwner: true,
  revision: 0,
});
const ONE = held("g-1", CY, "Could it also retry on 429, and honor Retry-After when the server sends it?");
const THREE = [
  ONE,
  held("g-2", DEV, "Please keep the max wait under 5 s so the upload button never looks stuck."),
  held("g-3", CY, "And log the final failure at warn, with the attempt count."),
];
const here = (...viewing: Participant[]) => ({ presence: { viewing, typing: [] } });
const title = { title: "Uploader retries", queueApproval: true };

const oneHeld = (): AcpmuxSnapshot => chat(done(), { ...title, ...here(CY), queue: [ONE] });
const looks = {
  bar: "B: Approve and Decline in a compact bar under the message, the label at the line's end.",
  menu: "C: the label at the line's end and a ⋯ menu beside it with Approve first, then Decline.",
};

export default agentPaneEntry({
  id: "agent-pane.guest-approval",
  title: "Agent pane: a guest's message waits for the owner",
  area: "Agent pane",
  keywords: ["multiplayer", "guest", "share", "approve", "decline", "held", "waiting for you"],
  covers: [
    "agent-session/acpmux/conversation/QueuedMessageCard.tsx",
    "agent-session/acpmux/conversation/queuedMessages.ts",
    "agent-session/acpmux/multiplayer/participants.ts",
  ],
  height: 620,
  variants: {
    held: {
      note: "A (the pick): one guest's message, held: their face and name (guest), Approve and Decline in the line's action area, then Waiting for you.",
      snapshot: oneHeld(),
      native: { "chat.queue.approve": {}, "chat.queue.decline": {} },
      afterCall: {
        "chat.queue.approve": chat(done(), { ...title, ...here(CY), queue: [{ ...ONE, awaitingOwner: undefined }] }),
      },
    },
    "three-held": {
      note: "Three held messages from two guests while the agent works, in arrival order, each with its own Approve and Decline.",
      snapshot: chat(working(), { ...title, ...here(CY, DEV), isWorking: true, queue: THREE }),
    },
    approved: {
      note: "Approved: the message waits as any queued message, with no note; nothing else of it is the owner's to change.",
      snapshot: chat(working(), {
        ...title,
        ...here(CY),
        isWorking: true,
        queue: [{ ...ONE, awaitingOwner: undefined }],
      }),
    },
    declined: {
      note: "Declined: one quiet line, Declined: and its first line, where it was declined; a click opens the whole text.",
      snapshot: chat(
        [
          ...done(),
          row(QUEUED_MESSAGE, 6, {
            id: "declined-g-9",
            text: ONE.prompt,
            incoming: { kind: "message", message: { name: CY.name, text: ONE.prompt, raw: ONE.prompt } },
            queuedMessage: { promptId: "g-9", person: CY, declined: true },
            untyped: true,
          }),
        ],
        { ...title, ...here(CY) },
      ),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".cv-declined__line"));
        ctx.document.querySelector<HTMLButtonElement>(".cv-declined__line")!.click();
        await ctx.waitFor(() => ctx.document.querySelector(".cv-declined__body"));
      },
    },
    teammate: {
      note: "Unchanged: a teammate's queued prompt on the tailnet stays a composer-queue row under their name.",
      snapshot: chat(working(), {
        ...title,
        ...here(ANA),
        isWorking: true,
        queue: [{ id: "t-1", prompt: "Then bump the client's timeout to 30 s", author: ANA }],
      }),
    },
    "look-bar": { note: looks.bar, snapshot: oneHeld(), documentAttributes: { "held-card-look": "bar" } },
    "look-menu": {
      note: `${looks.menu} Play: the menu open.`,
      snapshot: oneHeld(),
      documentAttributes: { "held-card-look": "menu" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector('[data-menu="held-message"]'));
        ctx.document.querySelector<HTMLButtonElement>('[data-menu="held-message"]')!.click();
        await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menuitem"]').length >= 2);
      },
    },
    "look-bar-three": {
      note: `${looks.bar} Three held, while the agent works.`,
      snapshot: chat(working(), { ...title, ...here(CY, DEV), isWorking: true, queue: THREE }),
      documentAttributes: { "held-card-look": "bar" },
    },
  },
});
