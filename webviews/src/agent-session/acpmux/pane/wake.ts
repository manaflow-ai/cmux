import { type ComposerWake } from "../Composer";
import { type ComposerAttachment } from "../attachments";
import { type ScrollAnchor } from "../VirtualTranscript";

/// The handshake's `wake` (AgentPaneWakeState.swift): what a released page held that acpmux does not.
/// `scrollAnchor`: the transcript's place, null at its latest message, undefined when unknown.
export function readWake(value: unknown):
  | {
      composer: ComposerWake;
      scrollAnchor?: ScrollAnchor | null;
      subagentDrafts?: unknown;
      folds?: unknown;
      subagentPane?: string;
    }
  | undefined {
  if (!value || typeof value !== "object") return undefined;
  const wake = value as {
    attachments?: unknown;
    shell?: unknown;
    shellText?: unknown;
    scrollAnchor?: unknown;
    atLatest?: unknown;
    subagentDrafts?: unknown;
    folds?: unknown;
    subagentPane?: unknown;
  };
  const anchor = wake.scrollAnchor as { rowId?: unknown; offset?: unknown } | null | undefined;
  return {
    composer: {
      attachments: Array.isArray(wake.attachments) ? (wake.attachments as ComposerAttachment[]) : undefined,
      shell: wake.shell === true,
      shellText: typeof wake.shellText === "string" ? wake.shellText : undefined,
    },
    scrollAnchor:
      typeof anchor?.rowId === "string" && typeof anchor.offset === "number"
        ? { rowId: anchor.rowId, offset: anchor.offset }
        : wake.atLatest === true
          ? null
          : undefined,
    subagentDrafts: wake.subagentDrafts,
    folds: wake.folds,
    // The subagent a subagent's pane showed (App.tsx `subagentPaneNow`): the page built again shows it.
    ...(typeof wake.subagentPane === "string" && wake.subagentPane ? { subagentPane: wake.subagentPane } : {}),
  };
}
