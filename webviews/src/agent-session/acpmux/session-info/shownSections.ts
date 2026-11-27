// Which of Session Info's sections a person has turned off in Settings > Agent Chat > Chat Layout
// (`agentPane.display.sessionInfo.sections.<id>`, schemas/settings/source/agent-pane-display.json):
// one toggle per section, every one on by default, so a person who sets nothing sees the panel as
// it was. A section turned off is not drawn at all (not folded, not under Show more); its order
// slot (sectionOrder.ts) stays, so turning it back on puts it where it was. The host sends the keys
// with the chat's other `agentPane.display.*` keys (chatDisplay.ts setChatDisplay).
import type { BuiltInSessionInfoSectionId, SessionInfoSectionId } from "./sessionInfoState";

export const SESSION_INFO_SECTION_KEY_PREFIX = "agentPane.display.sessionInfo.sections.";

/// The sections a setting can turn off: every built-in section the panel draws (SessionInfo.tsx),
/// in its default order (sectionOrder.ts DEFAULT_ORDER). Installed app sections have no row.
export const PICKABLE_SESSION_INFO_SECTIONS = [
  "environment",
  "context",
  "subagents",
  "tasks",
  "sources",
  "outputs",
  "changes",
  "usage",
  "connectors",
  "carried",
] as const satisfies readonly BuiltInSessionInfoSectionId[];

export type PickableSessionInfoSection = (typeof PICKABLE_SESSION_INFO_SECTIONS)[number];

export const sessionInfoSectionKey = (id: PickableSessionInfoSection): string => SESSION_INFO_SECTION_KEY_PREFIX + id;

/// The sections the display keys turn off, in the default order. Only `false` turns one off: an
/// unset key, `true` or a value of another type leaves it on.
export function hiddenSessionInfoSections(
  raw: Readonly<Record<string, unknown>>,
): readonly PickableSessionInfoSection[] {
  return PICKABLE_SESSION_INFO_SECTIONS.filter((id) => raw[sessionInfoSectionKey(id)] === false);
}

/// `nodes` without the hidden sections (the same object when none is hidden).
export function withoutHiddenSections<T>(
  nodes: Partial<Record<SessionInfoSectionId, T>>,
  hidden: readonly SessionInfoSectionId[],
): Partial<Record<SessionInfoSectionId, T>> {
  if (hidden.length === 0) return nodes;
  const shown = { ...nodes };
  for (const id of hidden) delete shown[id];
  return shown;
}
