// l10n-allow-file: gallery fixtures (question prompts and options), not shipped UI.
import { useEffect, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { COMPOSER_READY_EVENT } from "../composerFocus";
import { QuestionCard } from "./QuestionCard";
import type { AgentQuestion, QuestionReply } from "./model";
import answeredRemoteDevice from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/answered-remote-device.json";
import cancelled from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/cancelled.json";
import pendingFourQuestions from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-4-questions.json";
import pendingMultiFixture from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-multi.json";
import pendingOtherTyping from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-other-typing.json";
import pendingSingle from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-single.json";

type Props = {
  question: AgentQuestion;
  onReply(reply: QuestionReply): void;
};

const fixture = (question: unknown): AgentQuestion => question as AgentQuestion;

const pendingMulti = fixture(pendingMultiFixture);
const multiPreview: AgentQuestion = {
  ...pendingMulti,
  id: "perm_gallery_multi_preview",
  source: { ...pendingMulti.source, permission: "perm_gallery_multi_preview" },
  items: pendingMulti.items.map((item) => ({
    ...item,
    allowsOther: false,
    options: item.options.map((option) => ({
      ...option,
      preview: {
        format: "monospace",
        text: `Preview for ${option.label}\n\nThe highlighted choice stays visible while the list is navigated.`,
      },
    })),
  })),
};

function GalleryQuestionCard({ question, onReply }: Props) {
  const [reply, setReply] = useState<QuestionReply>();
  const [escaped, setEscaped] = useState(false);

  useEffect(() => {
    const onComposerReady = () => setEscaped(true);
    window.addEventListener(COMPOSER_READY_EVENT, onComposerReady);
    return () => window.removeEventListener(COMPOSER_READY_EVENT, onComposerReady);
  }, []);

  return (
    <div className="acpmux-question-gallery" data-question-gallery>
      <QuestionCard
        question={question}
        onReply={(next) => {
          setReply(next);
          onReply(next);
        }}
      />
      <output
        aria-live="polite"
        data-question-reply={reply ? (reply.answers ? "submitted" : "skipped") : undefined}
        data-question-escaped={escaped || undefined}
      >
        {reply?.answers ? "Submitted" : reply ? "Skipped" : escaped ? "Composer ready" : ""}
      </output>
    </div>
  );
}

const moveToPreview: Play = async (ctx) => {
  await ctx.focus({ selector: ".acpmux-question-row" });
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => Boolean(ctx.document.querySelector('[data-row="1"][data-highlighted]')));
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".acpmux-question-preview pre")?.textContent?.includes("iOS") ??
      false,
  );
};

const submitMulti: Play = async (ctx) => {
  await ctx.focus({ selector: ".acpmux-question-row" });
  await ctx.press("1");
  await ctx.press("4");
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector('[data-question-reply="submitted"]'));
};

const switchQuestion: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-question-tab:nth-child(2)" });
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".acpmux-question-prompt")?.textContent?.includes("platforms") ??
      false,
  );
};

const typeOther: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-question-other-choice" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-question-other input"));
  await ctx.type("A hosted identity provider", { selector: ".acpmux-question-other input" });
  await ctx.waitFor(
    () =>
      (ctx.document.querySelector<HTMLInputElement>(".acpmux-question-other input")?.value ??
        "") === "A hosted identity provider",
  );
};

const escapeToComposer: Play = async (ctx) => {
  await ctx.focus({ selector: ".acpmux-question-row" });
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.document.querySelector('[data-question-escaped="true"]'));
};

const skipQuestion: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Skip" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-question-reply="skipped"]'));
};

export default componentEntry<Props>({
  id: "agent-pane.question-card",
  title: "Agent question card",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/question/QuestionCard.tsx#QuestionCard"],
  load: async () => GalleryQuestionCard,
  styles: () => import("../styles.css"),
  widths: { narrow: 360, normal: 540, wide: 760 },
  height: 520,
  checks: {
    layoutShiftMax: {
      value: 0.05,
      reason: "Switching between prompts can change the in-flow option body while the question card remains in place.",
    },
    longFrameFailMs: {
      value: 33,
      reason:
        "Question selection, tab changes, and dismissal should remain responsive on the gallery host.",
    },
    settleMaxMs: {
      value: 350,
      reason:
        "Question-card keyboard and pointer actions should settle within a third of a second.",
    },
  },
  variants: {
    "pending-single": {
      note: "A pending question keeps the first row ready without stealing focus on arrival.",
      props: { question: fixture(pendingSingle), onReply: () => undefined },
    },
    "multi-preview": {
      note: "Multi-select choices keep a live preview while ArrowDown and number keys move through the rows.",
      props: { question: multiPreview, onReply: () => undefined },
      play: moveToPreview,
    },
    submit: {
      note: "Number keys toggle two choices and Enter submits the complete multi-select answer.",
      props: { question: multiPreview, onReply: () => undefined },
      play: submitMulti,
    },
    "four-tabs": {
      note: "A four-question ask keeps its tabs compact while moving between prompts.",
      props: { question: fixture(pendingFourQuestions), onReply: () => undefined },
      play: switchQuestion,
    },
    "other-typing": {
      note: "Other becomes an inline field and preserves the typed answer in the row.",
      props: { question: fixture(pendingOtherTyping), onReply: () => undefined },
      play: typeOther,
    },
    "answered-remote": {
      note: "An answered ask records the remote device that supplied the response.",
      props: { question: fixture(answeredRemoteDevice), onReply: () => undefined },
    },
    cancelled: {
      note: "A cancelled ask collapses to a quiet transcript status.",
      props: { question: fixture(cancelled), onReply: () => undefined },
    },
    escape: {
      note: "Escape hands the keyboard back to the composer without answering the ask.",
      props: { question: fixture(pendingSingle), onReply: () => undefined },
      play: escapeToComposer,
    },
    skip: {
      note: "Skip declines the pending ask and records the dismissal path.",
      props: { question: fixture(pendingSingle), onReply: () => undefined },
      play: skipQuestion,
    },
  },
});
