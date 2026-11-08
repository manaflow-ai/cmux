// Initial geometry of PermissionCard and QuestionCard, before their ResizeObserver reports.
// Keep the frame on the shared grid; interactive expansion is still measured by the transcript.
import { layout, prepare, prepareWithSegments, layoutWithLines } from "@chenglou/pretext";
import typeScale from "../../../../../schemas/type-scale/type-scale.json";
import { chatDisplay } from "../chatDisplay";
import { chatUiMeasureStack, chatUiTracking } from "../chatUiFont";
import type { AcpmuxPermission } from "../model";
import { currentLanguage, translate } from "../i18n";
import { plainText } from "../question/inlineText";
import { consentChoice, itemAnswerText, type AgentQuestion } from "../question/model";
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
  return chatUiMeasureStack(chatDisplay().uiFont);
}

/// The letter-spacing the card's text at `size` px is drawn with, in px: its type-scale step's
/// `--text-STEP--letter-spacing`, which the Interface Font sets (System UI, tight and cmux Inter
/// track; the stacks they share with System UI and Inter don't tell them apart). `step` names the
/// token when it isn't the size's own: the buttons draw body-size labels with detail's tracking.
export function cardLetterSpacing(size: number, step?: string): number {
  const name = step ?? typeScale.steps.find((entry) => entry.size === size)?.name;
  return name ? chatUiTracking(chatDisplay().uiFont, name) * size : 0;
}

// The same line breaker as prose estimates, using the card's UI font rather than chat text size.
function textHeight(text: string, width: number, size: number, line: number, mono = false, weight = 400): number {
  const room = Math.max(1, width);
  if (!mono) text = text.replace(/\s+/g, " ");
  try {
    return layout(
      prepare(text, `${weight} ${size}px ${mono ? "monospace" : cardFont()}`, {
        whiteSpace: "pre-wrap",
        letterSpacing: mono ? 0 : cardLetterSpacing(size),
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
  const key = `${width}/${scale}/${currentLanguage()}/${cardFont()}/${chatDisplay().uiFont}`;
  const cached = estimates.get(permission);
  if (cached?.key === key) return cached.height;
  const height = estimatePermission(permission, width, scale);
  estimates.set(permission, { key, height });
  return height;
}

// PermissionCard's frame (styles.css, .acpmux-permission-*): the request block is 16px around its
// title and description lines 4px apart; the details band adds 12px above the command and scope,
// 8px apart; the button row is 12px above and 16px below rows of 28px buttons, 8px apart.
const EDGE = 16;
const BAND = 12;
const GAP = 8;
const CONTROL_ROW = 28;

function estimatePermission(permission: AcpmuxPermission, width: number, scale: number): number {
  if (permission.question) return questionHeight(permission.question, width / scale) * scale;
  const room = Math.max(1, width / scale - 2 * EDGE);
  const external = permission.externalAccess;
  const plan = permission.plan;
  let height = 2 * EDGE + body.lineHeight;
  const description = external ? translate("permission.external.detail") : permissionDetail(permission);
  if (description) height += 4 + textHeight(description, room, body.size, body.lineHeight);
  // The plan's Markdown, inset 8 by 12 and scrolled past 320px.
  if (plan) height += 4 + Math.min(320, 16 + textHeight(plan, room - 24, detail.size, detail.size * 1.5));
  const { allowOnce, allowAlways, deny, others } = permissionAnswers(permission.options);
  const command = permissionCommand(permission);
  const scoped = !external && Boolean(permission.scope || (allowAlways && alwaysAllowScope(permission, allowAlways)));
  if (command || scoped) height += BAND;
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
  // Buttons are 12px either side of their label, which tracks as the detail step (styles.css).
  const button = (label: string, weight = 400) => textWidth(label, body.size, weight, "detail");
  const widths = labels.map((label, index) => button(label, allowOnce && index === 0 ? 500 : 400) + 24);
  for (const option of others) {
    const label = optionButtonLabel(option, translate, taken);
    taken.add(label);
    // Custom action labels are ellipsized at 14ch; transcript cards omit keyboard shortcuts.
    widths.push(Math.min(button(label), 14 * button("0")) + 24);
  }
  const rows = wrappedRows(widths, room, GAP);
  height += BAND + EDGE + rows * CONTROL_ROW + Math.max(0, rows - 1) * GAP;
  return height * scale;
}

function questionHeight(question: AgentQuestion, width: number): number {
  const room = Math.max(1, width - 2 * padding - 1);
  const text = (value: string, available = room, line = body.lineHeight, size = body.size, weight = 400) =>
    textHeight(plainText(value), available, size, line, false, weight);
  if (question.state.kind === "cancelled") {
    return 16 + 1 + question.items.reduce((sum, item) => sum + text(item.prompt) + 2, 0) + body.lineHeight;
  }
  if (question.state.kind === "answered") {
    const answer = question.state.answer;
    const by = answer.respondent;
    return (
      16 +
      1 +
      question.items.reduce((sum, item) => sum + text(item.prompt) + 2 + text(itemAnswerText(item, answer)) + 8, -8) +
      (by && (by.displayName || by.device || by.isRemote) ? 8 + detail.lineHeight : 0)
    );
  }
  const item = question.items[0];
  if (!item) return 24;
  const chip = item.header ? Math.min(room * 0.4, textWidth(item.header, caption.size, 600) + 16) + 8 : 0;
  const promptRoom = Math.max(1, room - chip);
  // Needs-input pill + gap, fieldset edges, then the 12px-padded header and its divider.
  let height = 24 + 8 + 1 + 2 * padding + text(item.prompt, promptRoom, body.lineHeight, body.size, 600) + 0.5;
  const consent = consentChoice(question);
  if (consent) {
    const scope = item.options[consent.accept]?.detail;
    if (scope) height += 4 + text(scope, promptRoom, detail.lineHeight, detail.size);
    return height + 12 + 28 + 8;
  }
  if (question.items.length > 1) {
    const tabs = question.items.map((each, index) => textWidth(String(each.header ?? index + 1), caption.size) + 16);
    const rows = wrappedRows(tabs, room, 4);
    height += 8 + rows * (caption.lineHeight + 4) + (rows - 1) * 4;
  }
  // List padding (4px), row padding (8px), and the 16px choice mark with its 8px gap.
  const optionRoom = Math.max(1, width - 1 - 8 - 16 - 24);
  height +=
    8 +
    item.options.reduce(
      (sum, option) =>
        sum +
        Math.max(
          36,
          16 +
            text(option.label, optionRoom, 19, body.size, 600) +
            (option.detail ? 2 + text(option.detail, optionRoom, detail.lineHeight, detail.size) : 0),
        ),
      0,
    );
  if (item.allowsOther) height += item.options.length ? 36 : 40;
  return height + 8 + 28 + 8;
}
