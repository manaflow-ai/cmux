// Initial geometry of PermissionCard and QuestionCard, before their ResizeObserver reports.
// Keep the frame on the shared grid; interactive expansion is still measured by the transcript.
import { layout, prepare, prepareWithSegments, layoutWithLines } from "@chenglou/pretext";
import "../measureContext";
import typeScale from "../../../../../schemas/type-scale/type-scale.json";
import { chatDensityTextScale, drawnFontSize, chatDisplay, chatMetrics } from "../chatDisplay";
import { chatUiFontVariables, chatUiMeasureStack, chatUiTracking } from "../chatUiFont";
import type { AcpmuxPermission } from "../model";
import { currentLanguage, translate } from "../i18n";
import { plainText } from "../question/inlineText";
import { consentChoice, hasPreviews, itemAnswerText, type AgentQuestion } from "../question/model";
import { HTML_PREVIEW_MIN_HEIGHT } from "../question/htmlPreviewModel";
import { questionPreviewLayout } from "../question/previewLayout.experiment";
import { previewText, shownPreview } from "../question/questionCardModel";
import { experimentArm } from "../../../experiments/experiment";
import type { NextStepAsk } from "../conversation/nextStepAsk";
import { gridLength } from "../transcriptGrid";
import {
  alwaysAllowScope,
  commandPreview,
  optionButtonLabel,
  permissionAnswers,
  permissionCommand,
  permissionDetail,
  permissionOptionKind,
} from "./prompt";

const step = (name: string) => typeScale.steps.find((entry) => entry.name === name)!;
const body = step("body");
const detail = step("detail");
const caption = step("caption");
const padding = gridLength("cards-padding");

/// The face the card is drawn in, `--font-ui`: the chat's Interface Font (chatUiFont.ts) as the
/// canvas can measure it, the macOS system stack by default. A canvas can't read CSS variables.
export function cardFont(): string {
  return chatUiMeasureStack(chatDisplay().uiFont, chatDisplay().uiFamily);
}

/// The letter-spacing the card's text at `size` px is drawn with, in px: its type-scale step's
/// `--text-STEP--letter-spacing`, which the Interface Font sets (System UI, tight and cmux Inter
/// track; the stacks they share with System UI and Inter don't tell them apart). `step` names the
/// token when it isn't the size's own: the buttons draw body-size labels with detail's tracking.
export function cardLetterSpacing(size: number, step?: string): number {
  const name = step ?? typeScale.steps.find((entry) => entry.size === size)?.name;
  // A font pack's family draws at its designed spacing (chatUiFontVariables).
  return name && !chatDisplay().uiFamily ? chatUiTracking(chatDisplay().uiFont, name) * size : 0;
}

// The same line breaker as prose estimates, using the card's UI font rather than chat text size.
function textHeight(
  text: string,
  width: number,
  size: number,
  line: number,
  mono = false,
  weight = 400,
  typography?: { font: string; letterSpacing: number; preserveWhitespace: boolean },
): number {
  const room = Math.max(1, width);
  if (!mono && !typography?.preserveWhitespace) text = text.replace(/\s+/g, " ");
  try {
    return layout(
      prepare(text, typography?.font ?? `${weight} ${size}px ${mono ? "monospace" : cardFont()}`, {
        whiteSpace: "pre-wrap",
        letterSpacing: typography?.letterSpacing ?? (mono ? 0 : cardLetterSpacing(size)),
      }),
      room,
      line,
    ).height;
  } catch {
    const columns = Math.max(1, Math.floor(room / (size * (mono ? 0.6 : 0.55))));
    return text.split("\n").reduce((count, part) => count + Math.max(1, Math.ceil(part.length / columns)), 0) * line;
  }
}

function textWidth(text: string, size: number, weight = 400, step?: string): number {
  try {
    return (
      layoutWithLines(
        prepareWithSegments(text, `${weight} ${size}px ${cardFont()}`, {
          letterSpacing: cardLetterSpacing(size, step),
        }),
        Infinity,
        size,
      ).lines[0]?.width ?? 0
    );
  } catch {
    return text.length * size * 0.55;
  }
}

function wrappedRows(widths: number[], room: number, gap: number): number {
  let rows = widths.length ? 1 : 0;
  let used = 0;
  for (const width of widths) {
    if (used && used + gap + width > room) {
      rows++;
      used = 0;
    }
    used += (used ? gap : 0) + width;
  }
  return rows;
}

const estimates = new WeakMap<AcpmuxPermission, { key: string; height: number }>();

export function permissionCardHeight(permission: AcpmuxPermission | undefined, width: number, scale = 1): number {
  if (!permission) return 2 * padding * scale + body.lineHeight * scale;
  // Immutable permission snapshots retain their estimate while unrelated reply tokens stream.
  // Keep only the current width per ask; old asks are released with their snapshot.
  // The font's stack and its name: two fonts that share a stack track differently.
  const key = `${width}/${scale}/${currentLanguage()}/${cardFont()}/${chatDisplay().uiFont}/${chatDisplay().font}/${drawnFontSize(chatDisplay())}/${chatDisplay().lineHeight}`;
  const cached = estimates.get(permission);
  if (cached?.key === key) return cached.height;
  const height = estimatePermission(permission, width, scale);
  estimates.set(permission, { key, height });
  return height;
}

// PermissionCard's frame (a Surface role="ask", ui/surface, the --surface-ask-* variables): 16px
// padding all round, the header row, the body, the command and scope, the edits and the answers as
// siblings 8px apart; the body's lines 4px apart; the answers rows of 28px buttons, 8px apart.
const EDGE = 16;
const GAP = 8;
const CONTROL_ROW = 28;
/// The width of the chevron segment a plan's Approve plan is joined to (styles.css `.acpmux-plan-build-chevron`).
const PLAN_BUILD_CHEVRON = 26;

function estimatePermission(permission: AcpmuxPermission, width: number, scale: number): number {
  // The prompt bubble's padding in the card's unscaled units: drawn at the density text scale (conversation.css).
  if (permission.question)
    return questionHeight(permission.question, width / scale, chatDensityTextScale() / scale) * scale;
  const room = Math.max(1, width / scale - 2 * EDGE);
  const external = permission.externalAccess;
  const plan = permission.plan;
  let height = 2 * EDGE + body.lineHeight;
  const description = external ? translate("permission.external.detail") : permissionDetail(permission);
  // The body slot is drawn only with a line or a plan in it; its lines are 4px apart.
  const lines: number[] = [];
  if (description) lines.push(textHeight(description, room, body.size, body.lineHeight));
  // The plan's Markdown, inset 8 by 12 and scrolled past 320px.
  if (plan) lines.push(Math.min(320, 16 + textHeight(plan, room - 24, detail.size, detail.size * 1.5)));
  if (lines.length) height += GAP + lines.reduce((sum, line) => sum + line, 0) + 4 * (lines.length - 1);
  const { allowOnce, allowAlways, deny, others } = permissionAnswers(permission.options);
  const command = permissionCommand(permission);
  const scoped = !external && Boolean(permission.scope || (allowAlways && alwaysAllowScope(permission, allowAlways)));
  if (command || scoped) height += GAP;
  if (command) {
    const preview = commandPreview(command);
    const line = detail.size * 1.5;
    const full = textHeight(preview.line, room - 2 * GAP, detail.size, line, true);
    height += 2 * GAP + Math.min(2 * line, full);
    if (preview.more || full > 2 * line) height += 4 + caption.size * 1.3;
  }
  if (scoped) height += (command ? GAP : 0) + caption.size * 1.3;
  const labels = [
    ...(allowOnce ? [translate(plan ? "permission.plan.approve" : "permission.allowOnce")] : []),
    ...(allowAlways
      ? [
          translate(
            permissionOptionKind(allowAlways) === "allow_chat" ? "permission.allowChat" : "permission.alwaysAllow",
          ),
        ]
      : []),
    ...(deny
      ? [translate(plan ? "permission.plan.keepPlanning" : external ? "permission.external.skip" : "permission.deny")]
      : []),
    ...(external ? [translate("permission.external.openSettings")] : []),
  ];
  const taken = new Set(labels);
  // Buttons are 12px either side of their label, which tracks as the detail step (styles.css); a
  // plan's Approve plan carries its build menu's chevron segment (PermissionCard `PlanBuildSplit`).
  const button = (label: string, weight = 400) => textWidth(label, body.size, weight, "detail");
  const widths = labels.map(
    (label, index) =>
      button(label, allowOnce && index === 0 ? 600 : 400) +
      24 +
      (plan && allowOnce && index === 0 ? PLAN_BUILD_CHEVRON : 0),
  );
  for (const option of others) {
    const label = optionButtonLabel(option, translate, taken);
    taken.add(label);
    // Custom action labels are ellipsized at 14ch; transcript cards omit keyboard shortcuts.
    widths.push(Math.min(button(label), 14 * button("0")) + 24);
  }
  const rows = wrappedRows(widths, room, GAP);
  height += GAP + rows * CONTROL_ROW + Math.max(0, rows - 1) * GAP;
  return height * scale;
}

function questionHeight(question: AgentQuestion, width: number, bubbleScale = 1): number {
  const room = Math.max(1, width - 2 * padding - 1);
  const text = (value: string, available = room, line = body.lineHeight, size = body.size, weight = 400) =>
    textHeight(plainText(value), available, size, line, false, weight);
  if (question.state.kind === "cancelled") {
    return 16 + 1 + question.items.reduce((sum, item) => sum + text(item.prompt) + 2, 0) + body.lineHeight;
  }
  if (question.state.kind === "answered") {
    const answer = question.state.answer;
    const by = answer.respondent;
    const display = chatDisplay();
    const metrics = chatMetrics(display);
    const tracking = chatUiFontVariables(display.uiFont, display.uiFamily)["--cv-tracking"];
    let letterSpacing = tracking ? Number.parseFloat(tracking) : 0;
    if (tracking?.endsWith("em")) letterSpacing *= drawnFontSize(display);
    // The bubble's 16 px sides and 10 px block padding (conversation.css .cv-user__bubble).
    const bubbleRoom = Math.max(1, width * 0.7 - 32 * bubbleScale);
    const bubbleText = (value: string) =>
      textHeight(plainText(value), bubbleRoom, drawnFontSize(display), metrics.lineHeight, false, 400, {
        font: metrics.measureFont,
        letterSpacing,
        preserveWhitespace: true,
      });
    return (
      20 * bubbleScale +
      question.items.reduce(
        (sum, item) => sum + bubbleText(item.prompt) + 2 + bubbleText(itemAnswerText(item, answer)) + 8,
        -8,
      ) +
      (by && (by.displayName || by.device || by.isRemote) ? 8 + detail.lineHeight : 0)
    );
  }
  const item = question.items[0];
  if (!item) return 24;
  // Every pending ask is one card on an 8 px inset (question/questionCard.css): the card's padding,
  // the "Needs your input" line, the question as a 14/20 title, 36 px rows, then a 36 px last row.
  const contentSize = drawnFontSize(chatDisplay());
  const titleLine = contentSize * (20 / 14);
  const inner = Math.max(1, width - 32);
  const consent = consentChoice(question);
  if (consent) {
    // No header line: the title, its scope line, and Deny and Allow (28 px buttons).
    let height = 16 + 8 + text(item.prompt, inner, titleLine, contentSize) + 8;
    const scope = item.options[consent.accept]?.detail;
    if (scope) height += 2 + text(scope, inner, body.lineHeight, body.size);
    return height + 28;
  }
  let height = 16 + 28 + 2 + text(item.prompt, inner, titleLine, contentSize) + 8;
  // The rows and the preview share the body, inside the card's 8 px padding (questionCard.css). The
  // preview the card opens with is the first row's, else the first one (QuestionCard `shownPreview`).
  const box = width - 16;
  const preview = hasPreviews(item) ? shownPreview(item.options, [0]) : undefined;
  const layout = preview ? experimentArm(questionPreviewLayout) : undefined;
  // Split and even put the preview beside the rows, by their flex basis and grow (styles.css), 8 px
  // apart, until the body is too narrow for both bases and the preview wraps under the rows.
  const flex = layout === "split" ? [220, 2, 280, 3] : layout === "even" ? [260, 1, 280, 1] : undefined;
  const beside = flex !== undefined && box >= flex[0]! + 8 + flex[2]!;
  const rowsWidth = beside ? flex[0]! + ((box - flex[0]! - 8 - flex[2]!) * flex[1]!) / (flex[1]! + flex[3]!) : box;
  // A row's label: the row's 8 px padding each side, the 20 px mark and its 10 px gap.
  const rowRoom = Math.max(1, rowsWidth - 46);
  let rows = item.options.reduce(
    (sum, option, index) =>
      sum +
      (index ? 2 : 0) +
      Math.max(
        36,
        16 +
          text(option.label, rowRoom, body.lineHeight, body.size) +
          (option.detail ? text(option.detail, rowRoom, detail.lineHeight, detail.size) : 0),
      ),
    0,
  );
  if (preview) {
    // Inline opens under its row, 2 px below it, past the mark; beside, the taller column sets the
    // height; under the rows, 8 px below them, the body's width.
    if (layout === "inline") rows += 2 + previewHeight(preview, rowsWidth - 38);
    else if (beside) rows = Math.max(rows, previewHeight(preview, box - rowsWidth - 8));
    else rows += 8 + previewHeight(preview, box);
  }
  height += rows;
  // The last row (8 px gap with its hairline, unless it is the only row); a narrow card wraps Skip
  // and Send under the typed answer.
  height += (item.options.length ? 8 : 0) + 36 + (item.allowsOther && inner < 320 ? 28 : 0);
  return height;
}

type QuestionOption = AgentQuestion["items"][number]["options"][number];

// An option's preview box (QuestionCard `OptionPreview`, questionCard.css): 8 px above, 12 px beside
// and below, its label 2 px down, then 8 px to the picture: a monospace block that keeps its lines
// (it scrolls sideways, never wraps), or an HTML frame at its least height until it reports one.
function previewHeight(option: QuestionOption, width: number): number {
  const label = translate("question.preview", { option: plainText(option.label) });
  const picture =
    option.preview?.format === "html"
      ? HTML_PREVIEW_MIN_HEIGHT
      : previewText(option.preview?.text ?? "").split("\n").length * detail.size * 1.45;
  return 8 + 2 + textHeight(label, width - 24, caption.size, caption.lineHeight) + 8 + picture + 12;
}

/// A tagged ask's card (conversation/NextStepCard.tsx, NextStepCard.css), the same in every pane: a
/// pane that cannot send draws the same rows read only and its reason in the typed answer's row.
/// Waiting: the 8 px inset, the 28 px "Needs your input" line, a wrap-up's recap (2 px over it, 8 under),
/// the question as a 14/20 title (8 lines at most) and its muted line (4 at most) in 8 px of side
/// padding, Show more under them when either is cut, then each answer's row, 2 px apart: 36 px, or its
/// label's lines when it wraps beside the number and the arrow; then the last row's 36 px under its 8 px
/// gap. Answered or superseded: 12 px over and under, the recap and 8 + 8 px under it, the question
/// and, 2 px under it, the answer, in 16 px of side padding. A recap alone: its box, 12 px over and
/// under, 16 px and the hairline at the sides.
export function nextStepCardHeight(
  ask: NextStepAsk,
  width: number,
  settled?: { answer?: string; superseded?: boolean },
): number {
  const room = Math.max(1, width - 32);
  const prose = (value: string, available = room) =>
    textHeight(plainText(value), available, body.size, body.lineHeight);
  if (!ask.question) return ask.recap ? 24 + 1 + prose(ask.recap, room - 1) : 0;
  if (settled && (settled.answer !== undefined || settled.superseded)) {
    const made = ask.options.find((option) => option.key && option.label === settled.answer)?.key;
    return (
      24 +
      (ask.recap ? prose(ask.recap) + 16 : 0) +
      prose(ask.question) +
      (settled.answer !== undefined ? 2 + prose(made ? translate(made) : settled.answer) : 0)
    );
  }
  const contentSize = drawnFontSize(chatDisplay());
  const titleLine = contentSize * (20 / 14);
  const question = textHeight(plainText(ask.question), room, contentSize, titleLine);
  const detailLines = ask.detail ? prose(ask.detail) : 0;
  let height = 16 + 28;
  if (ask.recap) height += 2 + prose(ask.recap) + 8;
  height +=
    2 + Math.min(8 * titleLine, question) + (ask.detail ? 2 + Math.min(4 * body.lineHeight, detailLines) : 0) + 8;
  // Show more: its caption line, 4 px tucked under the text and 8 px over the answers.
  if (question > 8 * titleLine + 0.5 || detailLines > 4 * body.lineHeight + 0.5) height += -4 + caption.lineHeight + 8;
  // A row's label: the row's 8 px padding each side, the 20 px number, the 12 px arrow, 10 px apart.
  const labelRoom = Math.max(1, width - 16 - 16 - 20 - 12 - 2 * 10);
  ask.options.forEach((option, index) => {
    const label = option.key ? translate(option.key) : plainText(option.label);
    height += (index ? 2 : 0) + Math.max(36, 16 + textHeight(label, labelRoom, body.size, body.lineHeight));
  });
  return height + (ask.options.length ? 8 + 36 : 0);
}
