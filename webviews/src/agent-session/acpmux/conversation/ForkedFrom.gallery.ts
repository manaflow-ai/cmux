// l10n-allow-file: gallery fixtures (sample chats and titles), not shipped UI.
// A fork's "Forked from <chat>" line (ForkedFromLine.tsx, #50086): the parent chat's name is a link
// that opens it, with the session hover card, where it was plain text. The fork opens under its
// parent's title plus " (fork)" (acpmux hub/titles.rs, #50024). The line's text is the English
// notice.forkedFrom string (Localizable.xcstrings): strings are not loaded when a gallery file is. `gone` is a fork whose parent left
// the list: the line stays plain text. Titles are made up.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { SESSION_ID, assistant, chat, row, session, summary, user } from "../../../gallery/fixtures/acpmux";

const PARENT_ID = "gallery-parent";
const PARENT = "Three-Dish Picnic Menu";
const FORK = `${PARENT} (fork)`;

const history = [
  user("Plan a three-dish picnic menu for six; one dish has to be vegetarian.", 30),
  assistant("Herb farro salad, lemon-garlic chicken thighs and a stone-fruit galette.", 29.5),
  summary(29.4, { status: "completed", durationMs: 18_000, toolCount: 0 }),
];

function forked(parentListed: boolean) {
  const line = parentListed
    ? row("notice", 12, {
        text: `Forked from ${PARENT}. Everything above is from that chat.`,
        forkedFrom: { parentId: PARENT_ID, chat: PARENT },
      })
    : row("notice", 12, { text: "Forked from another chat. Everything above is from that chat." });
  const sessions = [
    session({ sessionId: SESSION_ID, title: FORK }),
    ...(parentListed ? [session({ sessionId: PARENT_ID, title: PARENT, status: "idle" })] : []),
  ];
  return chat(
    [
      ...history,
      line,
      user("Same menu, but make the chicken a grilled halloumi so everything is vegetarian.", 11),
      assistant("Swapped in grilled halloumi with lemon and oregano; the salad and galette stay.", 10.5),
      summary(10.4, { status: "completed", durationMs: 12_000, toolCount: 0 }),
    ],
    { title: FORK, sessions },
  );
}

const CHIP = ".cv-forked-from .cv-forked-from__chat";

/// Rests the pointer on the parent chat's name: its hover card.
const hoverChip: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(CHIP), { capMs: 10_000 });
  await ctx.hover({ selector: CHIP });
};

const variants: Record<string, AgentPaneVariant> = {
  link: {
    note: "A fork titled from its parent; its Forked from line names the parent chat as a link that opens it.",
    snapshot: forked(true),
  },
  hover: {
    note: "The pointer on the parent chat's name: the session hover card, as on any session link.",
    snapshot: forked(true),
    play: hoverChip,
  },
  gone: {
    note: "The parent chat left the list: the line stays plain text, nothing to open.",
    snapshot: forked(false),
  },
};

export default agentPaneEntry({
  id: "agent-pane.forked-from",
  title: "Forked from",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: ["agent-session/acpmux/conversation/ForkedFromLine.tsx#ForkedFromLine"],
  variants,
});
