// l10n-allow-file: gallery fixtures, not shipped UI (the host sends the cards' text).
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { ToolCards } from "./ToolCards";
import type { ToolCard } from "./toolCardStore";

type Props = { initial: ToolCard[] };

const ask: ToolCard = {
  id: "cloud-move-tab_1",
  state: "ask",
  text: "The agent asks to move this chat to Cloud, copying demo-app to a Cloud machine.",
  actions: [
    { id: "move", title: "Move" },
    { id: "notNow", title: "Not now" },
    { id: "always", title: "Always", hint: "Move without asking whenever an agent in demo-app asks" },
  ],
};
const working: ToolCard = { id: ask.id, state: "working", text: "Moving this chat to Cloud…", actions: [] };
const always: ToolCard = {
  id: ask.id,
  state: "working",
  text: "Moving this chat to Cloud. Agents in demo-app move without asking.",
  actions: [{ id: "askFirst", title: "Ask first next time" }],
};
const failed: ToolCard = {
  id: ask.id,
  state: "failed",
  text: "Lost the connection to Move VM during the move. Retry to finish it.",
  actions: [
    { id: "retry", title: "Retry" },
    { id: "dismiss", title: "Dismiss" },
  ],
};

const started: ToolCard = {
  id: "cloud-start-session-tab_1",
  state: "done",
  text: "claude runs on Cloud machine dev. Its chat is in that machine's workspace in the sidebar.",
  actions: [
    { id: "open", title: "Open Chat" },
    { id: "dismiss", title: "Dismiss" },
  ],
};

const secret: ToolCard = {
  id: "cloud-access-fedcba9876543210fedcba9876543210",
  state: "ask",
  text: "An agent on Move VM asks you for the secret GITHUB_TOKEN. What you enter goes to this one request only. The agent says: to open a pull request",
  actions: [
    { id: "share", title: "Share once", submitsInput: true },
    { id: "deny", title: "Deny" },
  ],
  input: { placeholder: "Type or paste the secret", secure: true, maxBytes: 65536 },
};

/// The host's answers, as the app pushes them after each click.
const next: Record<string, ToolCard[]> = {
  move: [working],
  always: [always],
  askFirst: [working],
  retry: [working],
  notNow: [],
  open: [],
  dismiss: [],
  share: [],
  deny: [],
};

function GalleryToolCards({ initial }: Props) {
  const [cards, setCards] = useState(initial);
  return (
    <div className="acpmux-shell" data-tool-card-fixture>
      <div className="acpmux-composer">
        <div className="acpmux-permission">
          <ToolCards cards={cards} onAnswer={(_, action) => setCards(next[action] ?? cards)} />
        </div>
      </div>
    </div>
  );
}

const move: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Move" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-tool-card")?.getAttribute("data-state") === "working");
};

const notNow: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Not now" });
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-tool-card"));
};

const share: Play = async (ctx) => {
  await ctx.type("fake-secret", { selector: ".acpmux-tool-card-input" });
  await ctx.click({ role: "button", name: "Share once" });
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-tool-card"));
};

const askFirst: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Ask first next time" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-tool-card button").length === 0);
};

export default componentEntry<Props>({
  id: "agent-pane.tool-cards",
  title: "Tool cards (Move to Cloud ask)",
  area: "Agent pane",
  height: 150,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-tool-card-fixture]" }],
  covers: ["agent-session/acpmux/toolCards/ToolCards.tsx#ToolCards"],
  styles: () => import("../styles.css"),
  load: async () => GalleryToolCards,
  variants: {
    ask: { props: { initial: [ask] }, play: move },
    "not-now": { props: { initial: [ask] }, play: notNow },
    always: { props: { initial: [always] }, play: askFirst },
    failed: { props: { initial: [failed] } },
    started: { props: { initial: [started] } },
    secret: { props: { initial: [secret] } },
    "secret-share": { props: { initial: [secret] }, play: share },
  },
});
