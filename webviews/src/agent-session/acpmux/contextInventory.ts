import type { ContextPart } from "./ContextViewer";

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
          label: typeof part.label === "string" ? part.label : "Context",
          source: typeof part.source === "string" ? part.source : "harness",
          text: typeof part.text === "string" ? part.text : "The harness has not exposed this text.",
          textAvailable: typeof part.text === "string",
          tokenCount: count(part.tokens),
          measurement:
            part.measurement === "measured" || part.measurement === "estimated" ? part.measurement : "unavailable",
          applied: part.included !== false,
          channel: typeof part.channel === "string" ? part.channel : undefined,
        };
      })
    : [];
  const settings =
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
  return {
    parts,
    totalTokens: count(raw.providerTotalTokens),
    cmuxTokens: count(raw.cmuxTokens),
    maxTokens: count(raw.maxTokens),
    settings,
  };
}
