// Initial geometry of PermissionCard and QuestionCard, before their ResizeObserver reports.
// Keep the frame on the shared grid; interactive expansion is still measured by the transcript.
import { layout, prepare, prepareWithSegments, layoutWithLines } from "@chenglou/pretext";
import typeScale from "../../../../../schemas/type-scale/type-scale.json";
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

// The same line breaker as prose estimates, using the card's UI font rather than chat text size.
function textHeight(text: string, width: number, size: number, line: number, mono = false, weight = 400): number {
  const room = Math.max(1, width);
  if (!mono) text = text.replace(/\s+/g, " ");
  try {
    return layout(
      prepare(text, `${weight} ${size}px ${mono ? "monospace" : typeScale.font.family}`, {
        whiteSpace: "pre-wrap",
        letterSpacing: mono ? 0 : (typeScale.steps.find((entry) => entry.size === size)?.tracking ?? 0) * size,
      }),
      room,
      line,
    ).height;
  } catch {
    const columns = Math.max(1, Math.floor(room / (size * (mono ? 0.6 : 0.55))));
    return text.split("\n").reduce((count, part) => count + Math.max(1, Math.ceil(part.length / columns)), 0) * line;
  }
}

function textWidth(text: string, size: number, weight = 400): number {
  try {
    return (
      layoutWithLines(
        prepareWithSegments(text, `${weight} ${size}px ${typeScale.font.family}`, {
          letterSpacing: (typeScale.steps.find((entry) => entry.size === size)?.tracking ?? 0) * size,
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
  const key = `${width}/${scale}/${currentLanguage()}`;
  const cached = estimates.get(permission);
  if (cached?.key === key) return cached.height;
  const height = estimatePermission(permission, width, scale);
  estimates.set(permission, { key, height });
  return height;
}

function estimatePermission(permission: AcpmuxPermission, width: number, scale: number): number {
  if (permission.question) return questionHeight(permission.question, width / scale) * scale;
  const room = Math.max(1, width / scale - 2 * padding);
  let height = 2 * padding + Math.max(16, body.size * 1.35);
  const description = permissionDetail(permission);
  if (description) height += 8 + textHeight(description, room, detail.size, detail.size * 1.4);
  const command = permissionCommand(permission);
  if (command) {
    const preview = commandPreview(command);
    const line = detail.size * 1.5;
    const full = textHeight(preview.line, room - 16, detail.size, line, true);
    height += 8 + 16 + Math.min(2 * line, full);
    if (preview.more || full > 2 * line) height += 4 + caption.size * 1.3;
  }
  const { allowOnce, allowAlways, deny, others } = permissionAnswers(permission.options);
  const labels = [
    ...(allowOnce ? [translate("permission.allowOnce")] : []),
    ...(allowAlways
      ? [
          translate(
            permissionOptionKind(allowAlways) === "allow_chat" ? "permission.allowChat" : "permission.alwaysAllow",
          ),
        ]
      : []),
    ...(deny ? [translate("permission.deny")] : []),
  ];
  const taken = new Set(labels);
  const widths = labels.map(
    (label, index) => textWidth(label, body.size, allowOnce && index === 0 ? 500 : 400) + 2 * padding,
  );
  for (const option of others) {
    const label = optionButtonLabel(option, translate, taken);
    taken.add(label);
    // Custom action labels are ellipsized at 14ch; transcript cards omit keyboard shortcuts.
    widths.push(Math.min(textWidth(label, body.size), 14 * textWidth("0", body.size)) + 2 * padding);
  }
  const rows = wrappedRows(widths, room, 8);
  height += padding + rows * Math.max(24, body.size * 1.25 + 8) + Math.max(0, rows - 1) * 8;
  if (permission.scope || (allowAlways && alwaysAllowScope(permission, allowAlways))) height += 8 + caption.size * 1.3;
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
