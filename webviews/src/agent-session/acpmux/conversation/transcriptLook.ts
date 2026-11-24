// The transcript's look as data (schemas/transcript-look/transcript-look.json; Leo, 2026-11-18:
// "esp the like... claude style, chatgpt/codex style, and "studio" style things ... and ui
// improvements to the primitives ... similar to like a ui library or smth"). The JSON lists the
// tokens and the named looks; this module resolves `agentPane.display.transcriptLook` and
// `agentPane.display.transcriptTokens` from the host's `display` map into token values, and turns
// them into the conversation's CSS variables and root attributes (conversation/conversation.css)
// and the numbers the row estimator (model.ts) mirrors. No look has code of its own: a token a look
// leaves out, and every token of the cmux look, draws the stylesheet's value, so cmux is the chat as
// it drew before looks.
import data from "../../../../../schemas/transcript-look/transcript-look.json";
import { gridLength } from "../transcriptGrid";

export const TRANSCRIPT_LOOK_KEY = "agentPane.display.transcriptLook";
export const TRANSCRIPT_TOKENS_KEY = "agentPane.display.transcriptTokens";

export type TranscriptTokenSpec =
  | { name: string; kind: "choice"; choices: readonly string[]; default: string; description: string }
  | { name: string; kind: "number"; min: number; max: number; unit: string; default: number; description: string };
export interface TranscriptLookSpec {
  name: string;
  title: string;
  description: string;
  tokens: Readonly<Record<string, string | number>>;
}
export type TranscriptTokenValue = string | number;
export type TranscriptTokens = Partial<Record<string, TranscriptTokenValue>>;
export interface ResolvedTranscriptLook {
  /// The look's name, `cmux` when none (or an unknown one) is set.
  look: string;
  /// Every token that draws something other than the stylesheet's default: the person's valid
  /// override, else the look's value. A token absent here is the chat as it draws today.
  tokens: TranscriptTokens;
}

export const TRANSCRIPT_TOKENS = data.tokens as readonly TranscriptTokenSpec[];
// Through unknown: the JSON's inferred union of looks (each leaving most tokens out) stops overlapping
// the spec type once enough tokens are optional; validTokenValue checks every value at runtime.
export const TRANSCRIPT_LOOKS = data.looks as unknown as readonly TranscriptLookSpec[];
export const DEFAULT_TRANSCRIPT_LOOK = "cmux";
export const DEFAULT_RESOLVED_TRANSCRIPT_LOOK: ResolvedTranscriptLook = { look: DEFAULT_TRANSCRIPT_LOOK, tokens: {} };

const SPECS = new Map(TRANSCRIPT_TOKENS.map((spec) => [spec.name, spec]));
const LOOKS = new Map(TRANSCRIPT_LOOKS.map((look) => [look.name, look]));

/// `value` when it is valid for token `name` (one of its choices, or a finite number in its range),
/// else undefined: an unknown token, a wrong type or an out-of-range number is dropped, never clamped.
export function validTokenValue(name: string, value: unknown): TranscriptTokenValue | undefined {
  const spec = SPECS.get(name);
  if (!spec) return undefined;
  if (spec.kind === "choice") return typeof value === "string" && spec.choices.includes(value) ? value : undefined;
  return typeof value === "number" && Number.isFinite(value) && value >= spec.min && value <= spec.max
    ? value
    : undefined;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === "object" && !Array.isArray(value);

/// The host's `display` map (anything else: the cmux look). Per token: the override if valid, else
/// the look's value, else nothing.
export function resolveTranscriptLook(raw: unknown): ResolvedTranscriptLook {
  const values = isRecord(raw) ? raw : {};
  const name = values[TRANSCRIPT_LOOK_KEY];
  const look = (typeof name === "string" && LOOKS.get(name)) || LOOKS.get(DEFAULT_TRANSCRIPT_LOOK)!;
  const overrides = isRecord(values[TRANSCRIPT_TOKENS_KEY])
    ? (values[TRANSCRIPT_TOKENS_KEY] as Record<string, unknown>)
    : {};
  const tokens: TranscriptTokens = {};
  for (const spec of TRANSCRIPT_TOKENS) {
    const value =
      validTokenValue(spec.name, overrides[spec.name]) ?? validTokenValue(spec.name, look.tokens[spec.name]);
    if (value !== undefined) tokens[spec.name] = value;
  }
  return { look: look.name, tokens };
}

const num = (look: ResolvedTranscriptLook, name: string): number | undefined => {
  const value = look.tokens[name];
  return typeof value === "number" ? value : undefined;
};
const choice = (look: ResolvedTranscriptLook, name: string): string | undefined => {
  const value = look.tokens[name];
  return typeof value === "string" ? value : undefined;
};

/// The fallbacks the look gives the Agent Chat settings it overlaps (chatDisplay.ts): the person's
/// own `agentPane.display.*` key wins over each.
export function transcriptLookDisplayFallbacks(look: ResolvedTranscriptLook): {
  width?: number;
  font?: "system" | "serif" | "mono";
  fontSize?: number;
  lineHeight?: number;
} {
  return {
    width: num(look, "messageWidth"),
    font: choice(look, "font") as "system" | "serif" | "mono" | undefined,
    fontSize: num(look, "fontSize"),
    lineHeight: num(look, "lineHeight"),
  };
}

/// A face a look gives one part of the transcript (`reply.font`, `userMessage.font`).
export type TranscriptFace = "system" | "serif" | "mono";
const isFace = (value: unknown): value is TranscriptFace => value === "system" || value === "serif" || value === "mono";

/// The type a look gives the agent's reply prose and your messages apart from the chat's (Claude
/// sets replies in a serif and your messages in the sans): each face and size the look or the
/// person's tokens set; a field left out is the chat's own face or size.
export interface TranscriptPartType {
  replyFont?: TranscriptFace;
  replyFontSize?: number;
  promptFont?: TranscriptFace;
  promptFontSize?: number;
}
export function transcriptPartType(look: ResolvedTranscriptLook): TranscriptPartType {
  const face = (name: string) => {
    const value = choice(look, name);
    return isFace(value) ? value : undefined;
  };
  return {
    replyFont: face("reply.font"),
    replyFontSize: num(look, "reply.fontSize"),
    promptFont: face("userMessage.font"),
    promptFontSize: num(look, "userMessage.fontSize"),
  };
}

/// Which of `transcriptPartType`'s fields the person's own `agentPane.display.transcriptTokens` set
/// (validly). Those win over the Agent Chat font keys; a look's own value does not (chatDisplay.ts).
export function transcriptPartTypeFromTokens(raw: unknown): Record<keyof TranscriptPartType, boolean> {
  const values = isRecord(raw) ? raw : {};
  const overrides = isRecord(values[TRANSCRIPT_TOKENS_KEY])
    ? (values[TRANSCRIPT_TOKENS_KEY] as Record<string, unknown>)
    : {};
  const set = (name: string) => validTokenValue(name, overrides[name]) !== undefined;
  return {
    replyFont: set("reply.font"),
    replyFontSize: set("reply.fontSize"),
    promptFont: set("userMessage.font"),
    promptFontSize: set("userMessage.fontSize"),
  };
}

/// The plain prompt (`userMessage.style` plain): no fill, no corner, the whole column, left, a 4 pt
/// band above and below its 2 pt leading rule and 12 pt beside its text.
const PLAIN = { padBlock: 4, padInline: 12, share: 1 } as const;

/// The prompt's box as the estimator measures it, at text scale 1 (model.ts multiplies by the
/// chat's density text scale, as the CSS's --cv-bubble-scale does): block and inline padding per
/// side in px and the bubble's widest share of the column. Null fields are today's (BUBBLE).
export function userBubbleBox(look: ResolvedTranscriptLook): {
  padBlock: number | null;
  padInline: number | null;
  share: number | null;
} {
  if (choice(look, "userMessage.style") === "plain") return { ...PLAIN };
  return {
    padBlock: num(look, "userMessage.paddingBlock") ?? null,
    padInline: num(look, "userMessage.paddingInline") ?? null,
    share: num(look, "userMessage.maxWidth") ?? null,
  };
}

const DENSITY: Record<string, number> = { compact: 0.75, cozy: 1, comfortable: 1.25 };

/// The factor on every gap between the transcript's rows (model.ts places them): density's times
/// rowSpacing, 1 when neither is set.
export function gapScaleOf(look: ResolvedTranscriptLook): number {
  const density = choice(look, "density");
  return (density ? (DENSITY[density] ?? 1) : 1) * (num(look, "rowSpacing") ?? 1);
}

const percent = (fraction: number) => `${Math.round(fraction * 1000) / 10}%`;
/// A px length as grid units (`--grid-base`, 4 at Interface Size 1): the bubble's CSS multiplies
/// them by the grid base and its own scale, as its default 2.5, 4 and 3 are.
const units = (px: number) => `${Math.round((px / gridLength("base")) * 1000) / 1000}`;

/// The CSS variables for `look`; null leaves the stylesheet's default (every one, for cmux).
export function transcriptLookVariables(look: ResolvedTranscriptLook): Record<string, string | null> {
  const plain = choice(look, "userMessage.style") === "plain";
  const box = userBubbleBox(look);
  const radius = plain ? 0 : num(look, "userMessage.radius");
  const fill = plain ? 0 : num(look, "userMessage.fill");
  const align = plain ? "left" : choice(look, "userMessage.align");
  const card = num(look, "toolCard.radius");
  const code = num(look, "codeCard.radius");
  return {
    "--cv-user-bubble-pad-block": box.padBlock === null ? null : units(box.padBlock),
    "--cv-user-bubble-pad-inline": box.padInline === null ? null : units(box.padInline),
    "--cv-look-bubble-radius": radius === undefined ? null : units(radius),
    "--cv-user-bubble-share": box.share === null ? null : percent(box.share),
    "--cv-user-bubble-fill": fill === undefined ? null : percent(fill),
    "--cv-user-align": align === undefined ? null : align === "left" ? "flex-start" : "flex-end",
    // At the Interface Size, as the --grid-cards-radius they stand in for.
    "--cv-card-radius": card === undefined ? null : `calc(${card}px * var(--cmux-interface-scale, 1))`,
    "--cv-code-radius": code === undefined ? null : `calc(${code}px * var(--cmux-interface-scale, 1))`,
    ...toolTypeVariables(look),
  };
}

const set = (look: ResolvedTranscriptLook, name: string) => (look.tokens[name] === undefined ? null : "");

const face = (value: string | undefined) =>
  value === undefined ? null : value === "mono" ? "var(--cv-mono)" : "var(--cv-font)";

/// The tool rows' type (`toolRow.*`, `toolOutput.*`). The stylesheet reads each variable bare
/// (conversation.css "Tool row type"): unset, the declaration falls back to what the row inherits,
/// so the cmux look draws today's rows. A row's words sit on its fixed 20 pt line at any size the
/// token allows (at most the text size), so none moves a row; the output's size moves only an
/// opened call's body, which the row estimator never estimates (it measures it once drawn).
export function toolTypeVariables(look: ResolvedTranscriptLook): Record<string, string | null> {
  const rowSize = num(look, "toolRow.textSize");
  const weight = num(look, "toolRow.weight");
  const outputSize = num(look, "toolOutput.textSize");
  return {
    "--cv-tool-text-scale": rowSize === undefined ? null : String(rowSize),
    "--cv-tool-weight": weight === undefined ? null : String(weight),
    "--cv-tool-font": face(choice(look, "toolRow.font")),
    "--cv-tool-command-font": face(choice(look, "toolRow.commandFont")),
    "--cv-tool-output-scale": outputSize === undefined ? null : String(outputSize),
    "--cv-tool-output-font": face(choice(look, "toolOutput.font")),
  };
}

/// The root attributes for `look`'s choices the stylesheet draws by selector; null removes one.
export function transcriptLookAttributes(look: ResolvedTranscriptLook): Record<string, string | null> {
  return {
    "data-transcript-look": look.look === DEFAULT_TRANSCRIPT_LOOK ? null : look.look,
    "data-transcript-user": choice(look, "userMessage.style") ?? null,
    "data-transcript-timestamps": choice(look, "timestamps") ?? null,
    "data-transcript-tool-cards": choice(look, "toolCards") ?? null,
    "data-transcript-card-border": choice(look, "toolCard.border") ?? null,
    // Tool row type (toolTypeVariables): each rule draws only while its token is set.
    "data-transcript-tool-size": set(look, "toolRow.textSize"),
    "data-transcript-tool-weight": set(look, "toolRow.weight"),
    "data-transcript-tool-font": set(look, "toolRow.font"),
    "data-transcript-tool-command-font": set(look, "toolRow.commandFont"),
    "data-transcript-tool-output-size": set(look, "toolOutput.textSize"),
    "data-transcript-tool-output-font": set(look, "toolOutput.font"),
  };
}
