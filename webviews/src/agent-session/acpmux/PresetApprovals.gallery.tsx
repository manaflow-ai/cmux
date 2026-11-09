// l10n-allow-file: gallery fixtures, not shipped UI.
import { useMemo } from "react";
import { minutesAgo } from "../../gallery/clock";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { PresetApprovals, type PresetApprovalsLook } from "./PresetApprovals";
import type { PresetApprovalsClient } from "./presetApprovalsModel";

type Scenario = "needs" | "confirming" | "approved" | "blocked" | "error" | "all";
type Props = { look: PresetApprovalsLook; scenario: Scenario };

const machines = ["gcp-agent-lane-1", "gcp-agent-lane-2"];
const needs = {
  name: "agent-lane",
  harness: "claude",
  model: "claude-opus-5-5",
  effort: "medium",
  policy: "approve-all",
  description: "Fleet lanes that run without asking",
  digest: "3f9a1c0d7e5b42a8c6f1e0d9b8a7c6e5f4d3c2b1a0918273645546372819aabb",
  blocked: null,
  approval: null,
  runs: 0,
  lastRun: null,
  asks: [
    { at: minutesAgo(4), host: "gcp-agent-lane-1", from: "claude-sr2-coord" },
    { at: minutesAgo(31), host: "gcp-agent-lane-2", from: "claude-sr2-coord" },
    { at: minutesAgo(58), host: "gcp-agent-lane-1", from: "claude-sr2-coord" },
  ],
};
const approved = {
  ...needs,
  name: "review-lane",
  harness: "codex",
  model: "gpt-6-astra",
  effort: "high",
  policy: "review",
  description: "Read-only reviewers",
  approval: { by: "leoli", host: "cosmic-gray", at: minutesAgo(60 * 26) },
  runs: 14,
  lastRun: { at: minutesAgo(12), host: "gcp-agent-lane-2", sessionId: "s-review-14", from: "codex-review-coord" },
  asks: [],
};
const blocked = {
  ...needs,
  name: "local-debug",
  model: null,
  effort: null,
  policy: "approve-edits",
  description: "Debugging with a custom PATH",
  blocked: "preset.env",
  asks: [{ at: minutesAgo(9), host: "gcp-agent-lane-2", from: "claude-sr2-coord" }],
};

const ROWS: Record<Scenario, unknown[]> = {
  needs: [needs],
  confirming: [needs],
  approved: [approved],
  blocked: [blocked],
  error: [needs],
  all: [needs, approved, blocked],
};

/// The card on the home's column, on a stand-in for the pane's acpmux connection: the scenario's
/// presets, an approve that holds (`error`: refused as needing the person) and a revoke that clears.
function GalleryPresetApprovals({ look, scenario }: Props) {
  const client = useMemo<PresetApprovalsClient>(() => {
    const rows = structuredClone(ROWS[scenario]) as (typeof needs)[];
    return {
      presetApprovals: async () => ({ presets: rows, machines }),
      presetApprove: async (name, approve) => {
        if (scenario === "error")
          throw Object.assign(new Error("person required"), { data: { reason: "permission.person_required" } });
        const index = rows.findIndex((row) => row.name === name);
        rows[index] = {
          ...rows[index]!,
          approval: approve ? { by: "leoli", host: "cosmic-gray", at: minutesAgo(0) } : null,
        } as typeof needs;
        return rows[index];
      },
    };
  }, [scenario]);
  return (
    <div className="acpmux-shell" data-presets-fixture>
      <div className="acpmux-home-area">
        <PresetApprovals client={client} look={look} />
      </div>
    </div>
  );
}

const confirm: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-presets"));
  await ctx.click({ role: "button", name: "Approve" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-presets-confirm"));
};
const refused: Play = async (ctx) => {
  await confirm(ctx);
  await ctx.click({ role: "button", name: "Approve unattended runs" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-presets [role=alert]"));
};
const shown: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-presets"));
};

const LOOKS: Record<PresetApprovalsLook, string> = {
  list: "Inbox rows (the home's pick): the details under the name, answers under them, as Needs you's asks.",
  compact: "One line per preset with its button at the end; the confirm adds where it runs.",
  card: "Every detail on its own wrapped line, the description in the text color.",
};
const STATES: Record<Scenario, string> = {
  needs: "A preset a coordinator tried to dispatch while it was not approved.",
  confirming: "After the first Approve: the consequence in plain words and the approving second click.",
  approved: "Approved: who, on which Mac, its runs and the last one, with Revoke.",
  blocked: "A preset that sets a spawn env: why it cannot be approved, no button.",
  error: "The approve was refused (permission.person_required): the reason on the row.",
  all: "All three states together, as the home lists them.",
};
const PLAYS: Partial<Record<Scenario, Play>> = { confirming: confirm, error: refused };

const variants = Object.fromEntries(
  (Object.keys(LOOKS) as PresetApprovalsLook[]).flatMap((look) =>
    (Object.keys(STATES) as Scenario[]).map((scenario) => [
      `${look}-${scenario}`,
      {
        note: `${LOOKS[look]} ${STATES[scenario]}`,
        props: { look, scenario },
        play: PLAYS[scenario] ?? shown,
      },
    ]),
  ),
);

export default componentEntry<Props>({
  id: "agent-pane.preset-approvals",
  title: "Unattended runs (preset approvals)",
  area: "New Tab",
  height: 320,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: "[data-presets-fixture]" }],
  covers: ["agent-session/acpmux/PresetApprovals.tsx#PresetApprovals"],
  styles: () => import("./styles.css"),
  load: async () => GalleryPresetApprovals,
  variants,
});
