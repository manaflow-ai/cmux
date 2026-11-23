// l10n-allow-file: gallery fixtures, not shipped UI.
// A composer look climb's gallery entry (ui-climb, cmuxterm-hq tools/ui-climb): the composer
// entry's four climb states (conditions.json preset composer-v1: new-chat, draft, working, queued)
// under one experiment, so `ui-climb run` renders every arm in every state. An entry carries one
// experiment, so each composer look climb gets its own entry over the same states.
import { agentPaneEntry, type AgentPaneEntry } from "../../../gallery/format";
import type { Experiment } from "../../../experiments/experiment";
import type { PlayContext } from "../../../gallery/play";
import composer from "../composer.gallery";

export const CLIMB_STATES = ["new-chat", "draft", "working", "queued"] as const;

const boxDrawn = (ctx: PlayContext) =>
  ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer .acpmux-composer-box") !== null);

// Each entry's file writes its id as an `id: "<id>"` literal, where galleryEntryPath
// (test/support/galleryFrame.ts) finds it.
export function composerClimbEntry({
  id,
  title,
  definition,
}: {
  id: string;
  title: string;
  definition: Experiment;
}): AgentPaneEntry {
  return agentPaneEntry({
    id,
    title,
    area: "Agent pane",
    height: composer.height,
    widths: composer.widths,
    anchors: composer.anchors,
    checks: composer.checks,
    keywords: ["composer", "climb", definition.id],
    covers: ["agent-session/acpmux/Composer.tsx#Composer"],
    variants: Object.fromEntries(CLIMB_STATES.map((state) => [state, composer.variants[state]!])),
    experiment: { definition, script: [{ name: "Composer drawn", run: boxDrawn }] },
  });
}
