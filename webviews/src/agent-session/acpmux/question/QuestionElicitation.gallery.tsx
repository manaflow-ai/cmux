// l10n-allow-file: gallery fixtures, not shipped UI.
// An MCP server's elicitation form as the card asks it (acpmux claude_stdio/elicitation.rs): one
// item per field, answered by question text. Three looks of where the server's message goes in a
// form of several fields: lead (shipped: it leads the first field's question), every (it leads each
// one) and fields (only the fields, the message left to the tool title). A one-field form asks the
// message itself, under the server's name.
import { componentEntry } from "../../../gallery/format";
import type { AgentQuestion, Item } from "./model";
import { QuestionCard } from "./QuestionCard";

type Look = "lead" | "every" | "fields";
const message = "Where should this deploy go?";

const fields: Array<Omit<Item, "prompt"> & { label: string }> = [
  {
    id: "q0",
    label: "Region",
    header: "Region",
    options: [
      { id: "US East", label: "US East" },
      { id: "EU West", label: "EU West" },
    ],
    multiSelect: false,
    allowsOther: false,
  },
  { id: "q1", label: "Replicas", header: "Replicas", options: [], multiSelect: false, allowsOther: true },
  {
    id: "q2",
    label: "Canary",
    header: "Canary",
    options: [
      { id: "Yes", label: "Yes" },
      { id: "No", label: "No" },
    ],
    multiSelect: false,
    allowsOther: false,
  },
  {
    id: "q3",
    label: "Tags",
    header: "Tags",
    options: [
      { id: "Web", label: "Web" },
      { id: "API v2", label: "API v2" },
      { id: "No answer", label: "No answer" },
    ],
    multiSelect: true,
    allowsOther: false,
  },
];

const ask = (items: Item[]): AgentQuestion => ({
  id: "perm_elicitation",
  source: {
    harness: "claude",
    session: "sess_claude_1",
    permission: "perm_elicitation",
    agentName: "Deployer",
    answerOption: "allow_once",
    rejectOption: "reject_once",
  },
  items,
  state: { kind: "pending" },
});

const form = (look: Look): AgentQuestion =>
  ask(
    fields.map(({ label, ...item }, index) => ({
      ...item,
      prompt: look === "every" || (look === "lead" && index === 0) ? `${message} — ${label}` : label,
    })),
  );

const single = ask([
  {
    id: "q0",
    header: "github",
    prompt: "Which repository should the issue go to?",
    options: [
      { id: "cmux", label: "cmux" },
      { id: "cmux-gallery", label: "cmux-gallery" },
    ],
    multiSelect: false,
    allowsOther: false,
  },
]);

function ElicitationInPane({ question }: { question: AgentQuestion }) {
  return (
    <div className="acpmux-shell" style={{ flexDirection: "column", justifyContent: "flex-end", paddingTop: 16 }}>
      <div className="acpmux-permission">
        <div className="acpmux-asks-stack">
          <QuestionCard question={question} onReply={() => undefined} />
        </div>
      </div>
    </div>
  );
}

export default componentEntry({
  id: "agent-pane.question-card-elicitation",
  title: "Agent question card: an MCP server's form",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 420, normal: 640, wide: 820 },
  anchors: [{ selector: ".acpmux-question" }],
  covers: ["agent-session/acpmux/question/QuestionCard.tsx#QuestionCard"],
  styles: () => import("../styles.css"),
  load: async () => ElicitationInPane,
  variants: {
    lead: { note: "Shipped: the message leads the first field; a tab per field.", props: { question: form("lead") } },
    every: { note: "Alternative: the message leads every field.", props: { question: form("every") } },
    fields: { note: "Alternative: the fields only.", props: { question: form("fields") } },
    single: {
      note: "Shipped: a one-field form asks the message under the server's name.",
      props: { question: single },
    },
  },
});
