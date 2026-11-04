import { translate } from "./i18n";
import type { ContextPart, ContextSettings } from "./ContextViewer";

type RecordValue = Record<string, unknown>;
const record = (value: unknown): RecordValue => (value && typeof value === "object" ? (value as RecordValue) : {});
const count = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;

/** Decode only daemon-supplied evidence. Provider detail rows overlap, so never sum them. */
export function contextInventory(value: unknown) {
  const raw = record(value);
  const overrides = record(raw.overrides);
  const parts: ContextPart[] = Array.isArray(raw.parts)
    ? raw.parts.map((value, index) => {
        const part = record(value);
        return {
          id: typeof part.id === "string" ? part.id : `context-part-${index}`,
          label: typeof part.label === "string" ? part.label : translate("context.viewer.title"),
          source: typeof part.source === "string" ? part.source : "harness",
          text: typeof part.text === "string" ? part.text : translate("context.notExposed"),
          textAvailable: typeof part.text === "string",
          tokenCount: count(part.tokens),
          measurement:
            part.measurement === "measured" || part.measurement === "estimated" ? part.measurement : "unavailable",
          applied: part.included !== false,
          channel: typeof part.channel === "string" ? part.channel : undefined,
        };
      })
    : [];
  const settings: ContextSettings | undefined =
    "user" in overrides &&
    "project" in overrides &&
    raw.canEditOverrides === true &&
    typeof overrides.cwd === "string" &&
    overrides.cwd.length > 0
      ? {
          user: typeof overrides.user === "string" ? overrides.user : null,
          project: typeof overrides.project === "string" ? overrides.project : null,
          cwd: typeof overrides.cwd === "string" ? overrides.cwd : undefined,
          defaultText: typeof overrides.defaultText === "string" ? overrides.defaultText : undefined,
        }
      : undefined;
  if (settings && overrides.parts) {
    const parts: NonNullable<ContextSettings["parts"]> = {};
    for (const [id, value] of Object.entries(record(overrides.parts))) {
      const part = record(value);
      if (id !== "cmux-system-prompt" || typeof part.label !== "string" || !("user" in part && "project" in part))
        continue;
      parts[id] = {
        label: part.label,
        defaultText: typeof part.defaultText === "string" ? part.defaultText : undefined,
        user: typeof part.user === "string" ? part.user : null,
        project: typeof part.project === "string" ? part.project : null,
      };
    }
    if (Object.keys(parts).length) settings.parts = parts;
  }
  return {
    parts,
    totalTokens: count(raw.providerTotalTokens),
    cmuxTokens: count(raw.cmuxTokens),
    maxTokens: count(raw.maxTokens),
    settings,
  };
}
