// l10n-allow-file: gallery fixtures, not shipped UI.
// The agent question card on the shared CmuxAgentQuestion fixtures (the same asks the Swift card,
// acpmux and agent-question-card.test.ts use), so the gallery advisory run captures every state on
// Linux Chromium without a Mac, a tagged build or a logged-in agent.
import acpInteractive from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/acp-interactive.json";
import answeredCollapsed from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/answered-collapsed.json";
import answeredRemote from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/answered-remote-device.json";
import cancelled from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/cancelled.json";
import chiefAsks from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/chief-asks.json";
import codexUserInput from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/codex-user-input.json";
import pending4 from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-4-questions.json";
import pendingMulti from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-multi.json";
import pendingOther from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-other-typing.json";
import pendingSingle from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-single.json";
import pendingPreview from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-with-preview.json";
import { useEffect, useRef } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AgentQuestion, QuestionReply } from "./model";
import { questionPreviewLayout } from "./previewLayout.experiment";
import { QuestionCard } from "./QuestionCard";

type Props = {
  question: AgentQuestion;
  onReply(reply: QuestionReply): void | Promise<unknown>;
  otherText?: string;
  look?: "compact" | "inset" | "quiet";
};

/// The card sits where the agent pane puts it: inside .acpmux-shell (which defines the card tokens,
/// the amber input color among them) and the bottom ask stack.
function QuestionCardInPane({ otherText, look, ...props }: Props) {
  const pane = useRef<HTMLDivElement>(null);
  // A variant with `otherText` picks Other on the first question and types it, as a person does.
  useEffect(() => {
    const root = pane.current;
    if (!otherText || !root) return;
    // After the mount's effects, so the card's own update runs as it does for a click.
    const timer = setTimeout(() => {
      root.querySelector<HTMLElement>(".acpmux-question-other-choice")?.click();
      const field = root.querySelector<HTMLInputElement | HTMLTextAreaElement>(
        ".acpmux-question-other :is(input, textarea)",
      );
      if (!field) return;
      const prototype = field.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(prototype, "value")?.set?.call(field, otherText);
      field.dispatchEvent(new Event("input", { bubbles: true }));
    }, 0);
    return () => clearTimeout(timer);
  }, [otherText]);
  return (
    <div
      ref={pane}
      className="acpmux-shell acpmux-question-visual-gallery"
      data-question-look={look}
      style={{ flexDirection: "column", justifyContent: "flex-end", paddingTop: 16 }}
    >
      <div className="acpmux-permission">
        <div className="acpmux-asks-stack">
          <QuestionCard {...props} />
        </div>
      </div>
    </div>
  );
}

const variant = (question: unknown, note: string, otherText?: string) => ({
  note,
  props: { question: question as AgentQuestion, onReply: () => undefined, otherText },
});

/// The preview fixture with each mockup wrapped in a Markdown fence, as agents often send it: the
/// card's monospace box stands for the fence, so the fence lines do not show.
const fenced = (question: AgentQuestion): AgentQuestion => ({
  ...question,
  items: question.items.map((item) => ({
    ...item,
    options: item.options.map((option) =>
      option.preview
        ? { ...option, preview: { ...option.preview, text: `\`\`\`text\n${option.preview.text}\n\`\`\`` } }
        : option,
    ),
  })),
});

/// A Claude Code AskUserQuestion of a sub-session, answered by the session that started it
/// (acpmux `subsession_answer.rs`): the record names that session, never a person.
const answeredBySession: AgentQuestion = {
  ...(answeredCollapsed as unknown as AgentQuestion),
  state: {
    kind: "answered",
    answer: {
      selections: { q0: { optionIDs: ["OAuth 2.0"] } },
      respondent: { displayName: "lead-planner", isRemote: false, isSession: true },
    },
  },
};

/// How an unanswered ask ended, as its record says (record.ts `cancelReason`).
const skipped: AgentQuestion = {
  ...(cancelled as unknown as AgentQuestion),
  state: { kind: "cancelled", reason: "skipped" },
};
const stopped: AgentQuestion = {
  ...(cancelled as unknown as AgentQuestion),
  state: { kind: "cancelled", reason: "stopped" },
};

/// Answered from the person's phone through the feed (`answeredBy {device, feedItem}`): the record
/// names an install, not a device, so the line says another device.
const answeredElsewhere: AgentQuestion = {
  ...(answeredCollapsed as unknown as AgentQuestion),
  state: {
    kind: "answered",
    answer: { selections: { q0: { optionIDs: ["OAuth 2.0"] } }, respondent: { isRemote: true } },
  },
};

/// Leo's ask (2026-10-20): two Claude Code questions, tabbed New tab pick | References.
const pendingTwo: AgentQuestion = {
  id: "perm_toolu_two",
  source: {
    harness: "claude",
    session: "sess_claude_1",
    permission: "perm_toolu_two",
    agentName: "Claude Code",
    answerOption: "allow_once",
    rejectOption: "reject_once",
  },
  items: [
    {
      id: "q0",
      header: "New tab pick",
      prompt: "When I open a new tab, which page should it show?",
      options: [
        { id: "Start page", label: "Start page", detail: "The default start page with recent folders." },
        { id: "Last folder", label: "Last folder", detail: "Reopen the folder of the last tab." },
      ],
      multiSelect: false,
      allowsOther: true,
    },
    {
      id: "q1",
      header: "References",
      prompt: "Which references should the plan cite?",
      options: [
        { id: "Design doc", label: "Design doc", detail: "plans/cmux-next/new-tab.md" },
        { id: "None", label: "None" },
      ],
      multiSelect: false,
      allowsOther: true,
    },
  ],
  state: { kind: "pending" },
};

/// The card the daemon raises when an agent wants a sub-session in a folder nobody answered the trust
/// question for (hub/trust_wait.rs): a choice question from cmux, answered by the picked option.
const folderTrust: AgentQuestion = {
  id: "perm_trust_1",
  source: {
    harness: "acp",
    session: "sess_claude_1",
    permission: "perm_trust_1",
    agentName: "cmux",
    answerOption: "trust",
    rejectOption: "not_now",
  },
  items: [
    {
      id: "q0",
      header: "Folder trust",
      prompt: "split-importer wants to work in /Users/you/src/vendor-sdk. Do you trust this folder?",
      options: [
        {
          id: "trust",
          label: "Trust folder",
          detail: "cmux stops asking about this folder. Your permission rules still apply.",
        },
        {
          id: "not_now",
          label: "Not now",
          detail: "The sub-session does not start, and the agent is told you declined.",
        },
      ],
      multiSelect: false,
      allowsOther: false,
    },
  ],
  state: { kind: "pending" },
};

/// Puts the pointer on option `row`.
const hoverRow =
  (row: number): Play =>
  (ctx) =>
    ctx.hover({ selector: `.acpmux-question-row[data-row="${row}"]` });

/// The highlight stays inside the card, and moving it never shifts the question or footer.
/// Runs in the real React gallery with trusted browser input in the matrix runner.
const checkInsetRows: Play = async (ctx) => {
  const card = ctx.find({ selector: ".acpmux-question" });
  const row = ctx.find({ selector: '.acpmux-question-row[data-row="1"]' });
  const prompt = ctx.find({ selector: ".acpmux-question-prompt" });
  const actions = ctx.find({ selector: ".acpmux-question-actions" });
  const box = card.getBoundingClientRect();
  const rowBox = row.getBoundingClientRect();
  if (rowBox.left < box.left + 5 || rowBox.right > box.right - 5)
    throw new Error("The row highlight must be inset from both card edges.");
  for (const target of card.querySelectorAll(".acpmux-question-row")) {
    const rect = target.getBoundingClientRect();
    if (rect.height < 36 || target.scrollWidth > target.clientWidth + 1)
      throw new Error("Question choices need a full click target without horizontal overflow.");
  }
  const before = [box, prompt.getBoundingClientRect(), actions.getBoundingClientRect()];
  await ctx.hover({ selector: '.acpmux-question-row[data-row="1"]' });
  await ctx.press("ArrowDown");
  const after = [card, prompt, actions].map((node) => node.getBoundingClientRect());
  if (
    before.some((rect, i) =>
      ["x", "y", "width", "height"].some(
        (key) => Math.abs((rect[key as keyof DOMRect] as number) - (after[i]![key as keyof DOMRect] as number)) > 0.5,
      ),
    )
  )
    throw new Error("Question layout moved while its highlight changed.");
};

export default componentEntry({
  id: "agent-pane.question-card",
  title: "Agent question card",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 420, normal: 640, wide: 820 },
  anchors: [{ selector: ".acpmux-question" }],
  covers: ["agent-session/acpmux/question/QuestionCard.tsx#QuestionCard"],
  styles: () => Promise.all([import("../styles.css"), import("./QuestionCard.gallery.css")]),
  load: async () => QuestionCardInPane,
  experiment: {
    definition: questionPreviewLayout,
    script: [
      { name: "hover Tabs", run: hoverRow(1) },
      { name: "arrow to Single scroll", run: (ctx) => ctx.press("ArrowDown") },
    ],
  },
  variants: {
    "visual-compact": {
      ...variant(pendingSingle, "Compact rules: tighter rows and footer, with full-width hairlines."),
      props: { ...variant(pendingSingle, "").props, look: "compact" },
    },
    "visual-inset": {
      ...variant(pendingSingle, "Recommended: inset row highlights, quiet separators, compact footer."),
      props: { ...variant(pendingSingle, "").props, look: "inset" },
      play: checkInsetRows,
    },
    "visual-quiet": {
      ...variant(pendingSingle, "Quiet list: no header strip or row separators; the prompt leads the list."),
      props: { ...variant(pendingSingle, "").props, look: "quiet" },
    },
    "pending-single": variant(
      pendingSingle,
      "A Claude Code AskUserQuestion: the Needs your input pill, the question as the header, radio rows, Skip and Submit.",
    ),
    "folder-trust": variant(
      folderTrust,
      "An agent's sub-session waits in an untrusted folder: Trust folder or Not now. Trust lets the start go on by itself.",
    ),
    "folder-trust-picked": {
      ...variant(folderTrust, "Trust folder clicked: the row is chosen and nothing is sent until Submit (or ⌘↩)."),
      play: (ctx) => ctx.click({ selector: '.acpmux-question-row[data-row="0"]' }),
    },
    "pending-multi": variant(pendingMulti, "A multi-select ask: checkbox rows."),
    "pending-other-typing": variant(pendingOther, "Other turned into an inline text field."),
    "pending-with-preview": variant(
      pendingPreview,
      "Options with a preview (Claude Code's `preview` field): a narrower list and the highlighted option's mockup beside it; under about 520 px it wraps under the list.",
    ),
    "pending-with-preview-hover": {
      ...variant(pendingPreview, "The pointer on Tabs: the preview follows the hovered option, the highlight stays."),
      play: hoverRow(1),
    },
    "pending-with-preview-fenced": variant(
      fenced(pendingPreview as unknown as AgentQuestion),
      "Previews sent inside a Markdown fence: the box stands for the fence, so no backticks show.",
    ),
    "pending-4-questions": variant(pending4, "Four questions in one ask."),
    "codex-user-input": variant(
      codexUserInput,
      "A Codex user-input request: two questions, the second free text only (no options).",
    ),
    "acp-interactive": variant(
      acpInteractive,
      "An interactive ACP permission: its permission options as the choices, no Other.",
    ),
    "chief-asks": variant(chiefAsks, "The Chief's own question."),
    "reply-refused": {
      ...variant(pendingSingle, "acpmux refused the answer: the card says so and takes input again for a retry."),
      props: {
        question: pendingSingle as unknown as AgentQuestion,
        onReply: () => Promise.reject(new Error("the ask is no longer pending")),
      },
      play: async (ctx) => {
        await ctx.click({ selector: '.acpmux-question-row[data-row="0"]' });
        await ctx.click({ selector: ".acpmux-question-submit" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-question-error"));
      },
    },
    answered: variant(
      answeredCollapsed,
      "Answered: one line per question (header: the chosen answers), and who answered.",
    ),
    "answered-remote": variant(
      answeredRemote,
      "Answered from a paired phone: the line names the person and the device.",
    ),
    "answered-by-session": variant(
      answeredBySession,
      "A sub-session's question answered by the session above it: named as that session, never a person.",
    ),
    cancelled: variant(
      cancelled,
      "Ended unanswered where the record can't say how (no reject option): one muted line, Not answered, and the question.",
    ),
    skipped: variant(skipped, "The person pressed Skip: the line says Skipped."),
    stopped: variant(stopped, "The turn was stopped (or the chat closed) before an answer: the line says so."),
    "answered-elsewhere": variant(
      answeredElsewhere,
      "Answered on the person's phone through the feed, which names an install, not a device: another device.",
    ),
    "pending-2-other-typed": variant(
      pendingTwo,
      "Two questions, Other picked and typed on the first: the button says Next, Enter goes to References.",
      "idk",
    ),
  },
});
