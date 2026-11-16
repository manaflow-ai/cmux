// l10n-allow-file: gallery fixtures exercise the list's shipped labels and update states.
// Harness updates available (Leo 2026-11-12, ask-3fdf0982ec): the model menus' footer listing every
// outdated agent CLI, as a menu panel draws it. The reference listed Codex and OpenCode; here Claude
// Code is the chat's own (its offer: Skip This Version, Restart Chat after) beside the others.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { HarnessUpdatesSection } from "./HarnessUpdates";
import { type HarnessHealth, type UpdateOffer } from "./harnessHealthNoticeModel";
import { useHarnessUpdateList } from "./harnessUpdateList";
import { agentDisplayName } from "./agents";

const row = (id: string, version: string, latest: string, command: string): HarnessHealth => ({
  id,
  version,
  latest,
  outdated: true,
  update: { command, elevated: false },
});
const codex = row("codex", "0.164.0", "0.167.2", "npm install -g @openai/codex@latest");
const opencode = row("opencode", "1.19.0", "1.19.5", "npm install -g opencode-ai@latest");

type Props = {
  /// The chat's own agent's offer (Claude Code), when it has one.
  own?: boolean;
  rows: HarnessHealth[];
  /// How the host's `harness.update` answers: done, failed, or still running.
  updater?: "ok" | "fails" | "pending";
};

function GalleryHarnessUpdates({ own = false, rows, updater = "ok" }: Props) {
  const [calls, setCalls] = useState<string[]>([]);
  const offer: UpdateOffer | undefined = own
    ? {
        harness: "claude",
        agent: "Claude Code",
        version: "2.1.30",
        latest: "2.1.34",
        update: () => setCalls((list) => [...list, "offer.update"]),
        skip: () => setCalls((list) => [...list, "offer.skip"]),
      }
    : undefined;
  const updates = useHarnessUpdateList({
    rows,
    offer,
    own: own ? "claude" : undefined,
    nameFor: agentDisplayName,
    native: (method, params) => {
      setCalls((list) => [...list, `${method} ${String(params.id)}`]);
      if (updater === "pending") return new Promise<never>(() => undefined);
      return Promise.resolve(
        updater === "fails" ? { ok: false, error: "npm error code EACCES\nnpm error errno -13" } : { ok: true },
      );
    },
    onUpdated: () => undefined,
  });
  return (
    // A menu panel's frame: the footer sits under the model list it belongs to.
    <div className="acpmux-quick-menu ui-menu-popup" data-harness-calls={calls.join(", ")} style={{ width: 360 }}>
      {updates ? <HarnessUpdatesSection updates={updates} /> : <p>No updates</p>}
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.harness-updates",
  title: "Harness updates available",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 300, normal: 360, wide: 420 },
  covers: ["agent-session/acpmux/HarnessUpdates.tsx#HarnessUpdatesSection"],
  styles: () => import("./styles.css"),
  load: async () => GalleryHarnessUpdates,
  variants: {
    "three-harnesses": {
      note: "The chat's Claude Code (with Skip This Version), Codex and OpenCode: one row each, Update all in the heading.",
      props: { own: true, rows: [codex, opencode] },
    },
    "reference-pair": {
      note: "The reference's pair, Codex and OpenCode, in a chat whose own agent is current.",
      props: { rows: [codex, opencode] },
    },
    "one-harness": {
      note: "One outdated agent: no Update all, the row's Update is the whole action.",
      props: { rows: [opencode] },
    },
    updating: {
      note: "Update all started: each row's Update is a spinner until the host's updater answers.",
      props: { rows: [codex, opencode], updater: "pending" },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-harness-updates-all" });
        await ctx.waitFor(() => ctx.document.querySelectorAll('[data-phase="updating"]').length === 2);
      },
    },
    "update-failed": {
      note: "A failed update says so on its row (the updater's words on hover) and offers Try Again.",
      props: { rows: [codex], updater: "fails" },
      play: async (ctx) => {
        await ctx.click({ selector: '[data-harness-update="codex"] .acpmux-harness-update-run' });
        await ctx.waitFor(() => ctx.document.querySelector('[data-phase="failed"]') !== null);
      },
    },
  },
});
