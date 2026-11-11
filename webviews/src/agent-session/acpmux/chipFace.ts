// Lawrence 2026-11-10, on a composer chip that drew the OpenAI logo beside "Opus 5.5 Medium": "need to
// make this state impossible". The chip's logo, its model's name and its effort are one value, a
// ``ChipFace``, made only here and only from the model the chip names: the logo is that model's own
// provider, read off its id (never its display name, which a live list may shorten, and never the
// harness that runs it: a Codex harness behind a router runs Opus, and Opus is Claude's). Only a chip
// that names no model (a harness still starting, the bare harness name) draws its harness's mark.

declare const chipFaceBrand: unique symbol;

/// What the model chip draws: its logo (an AgentMark key), its text and its effort level.
export type ChipFace = {
  readonly mark: string | undefined;
  readonly name: string;
  /// The model the face names, when it names one; its provider chose `mark`.
  readonly model?: string;
  /// The effort level the chip writes after the name ("Medium"), when there is one.
  readonly detail?: string;
  /// The detail's short form for a narrow row ("Med").
  readonly detailShort?: string;
  /// Only `modelFace` and `harnessFace` make a face, so no caller sets a logo by hand.
  readonly [chipFaceBrand]: true;
};

type Detail = { detail?: string; detailShort?: string };

/// The AgentMark key of the provider whose model `id` is, from the id alone; undefined for a model
/// no known provider makes (a custom harness's own model, "default"). A router prefix
/// ("openrouter/anthropic/claude-opus-5-5", "opencode/gpt-6") is read through to the model's part.
export function providerMark(id: string | undefined): string | undefined {
  if (!id) return undefined;
  const parts = id.toLowerCase().split("/");
  for (let index = parts.length - 1; index >= 0; index -= 1) {
    const mark = markOf(parts[index]!);
    if (mark) return mark;
  }
  return undefined;
}

function markOf(raw: string): string | undefined {
  // "claude-opus-5-5[1m]", "opus[1m]": the bracket names a context size, not a model.
  const id = raw.replace(/\[[^\]]*\]$/, "");
  if (/^(?:anthropic|claude)(?:$|-)/.test(id) || /^(?:opus|sonnet|haiku|fable)(?:$|plan$|[-.\d])/.test(id))
    return "claude";
  if (/^(?:openai|gpt|chatgpt|codex)(?:$|-)/.test(id) || /^o\d+(?:$|-)/.test(id)) return "openai";
  if (/^(?:google|gemini|gemma)(?:$|-)/.test(id)) return "gemini";
  if (/^deepseek(?:$|-)/.test(id)) return "deepseek";
  if (/^(?:mistral|devstral|codestral|magistral|ministral)(?:$|-)/.test(id)) return "mistral";
  if (/^(?:qwen|qwq|alibaba)/.test(id)) return "qwen";
  if (/^(?:meta|meta-llama|llama|muse)(?:$|-)/.test(id)) return "meta";
  if (/^(?:xai|x-ai|grok)(?:$|-)/.test(id)) return "grok";
  if (/^(?:moonshotai|moonshot|kimi)(?:$|-)/.test(id)) return "kimi";
  return undefined;
}

/// The face of a chip that names `model` as `name`. Its logo is the model's provider; only a model
/// no known provider makes takes `harnessMark` (it is that harness's own model).
export function modelFace(model: string, name: string, harnessMark: string | undefined, detail: Detail = {}): ChipFace {
  return {
    mark: providerMark(model) ?? harnessMark,
    name,
    model,
    ...(detail.detail ? { detail: detail.detail } : {}),
    ...(detail.detailShort && detail.detailShort !== detail.detail ? { detailShort: detail.detailShort } : {}),
  } as ChipFace;
}

/// The face of a chip that names no model, only a harness (or a step of its setup): its mark.
export function harnessFace(harnessMark: string | undefined, name: string, detail: Detail = {}): ChipFace {
  return {
    mark: harnessMark,
    name,
    ...(detail.detail ? { detail: detail.detail } : {}),
    ...(detail.detailShort && detail.detailShort !== detail.detail ? { detailShort: detail.detailShort } : {}),
  } as ChipFace;
}

/// The face of a chip that names `model` when it knows one, else only its harness.
export function chipFace(
  model: string | undefined,
  name: string,
  harnessMark: string | undefined,
  detail: Detail = {},
): ChipFace {
  return model ? modelFace(model, name, harnessMark, detail) : harnessFace(harnessMark, name, detail);
}
