// l10n-allow-file: gallery fixture prose for a design pick, not shipped UI; the picked look's words go
// into the catalog with the change that ships it.
// RFD 0167 row 16: a task's cost shown at its turn's end. acpmux (cmux#54197, hub/turn_cost.rs) puts
// modelCostUsd, computeCostUsd, taskCostUsd and sessionCostUsd on every turn_result within ~2 ms of the
// turn's end (60-turn bench p95 0.0017 s); this entry picks how the reply footer shows them. Three
// looks: a row in the reply time's tooltip, the turn's cost inline after the footer's buttons, and a
// chip whose tooltip splits model from machine and carries the chat's running total. Fixtures are real
// shapes: a Claude turn on a Freestyle VM, a Codex turn on the person's Mac (no compute), and an older
// turn with no cost recorded (draws nothing).
import type { CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";

type Look = "tooltip-row" | "inline" | "chip";
type Cost = { model: number; compute?: number; session: number; source: "reported" | "estimated" };
type Turn = { worked: string; cost?: Cost };
type Props = { look: Look; turns: readonly Turn[] };

const TURNS: readonly Turn[] = [
  { worked: "1m 16s", cost: { model: 0.4213, compute: 0.0021, session: 3.1702, source: "reported" } },
  { worked: "4m 2s", cost: { model: 0.0874, session: 0.6619, source: "estimated" } },
  { worked: "9m 31s" },
];

const usd = (value: number) =>
  new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: value < 0.1 ? 3 : 2,
  }).format(value);

const total = (cost: Cost) => cost.model + (cost.compute ?? 0);

const detail = (cost: Cost) =>
  [
    `This task ${usd(total(cost))}${cost.source === "estimated" ? " (estimated)" : ""}`,
    `Model ${usd(cost.model)}${cost.compute === undefined ? "" : ` · machine ${usd(cost.compute)}`}`,
    `This chat so far ${usd(cost.session)}`,
  ].join("\n");

const FOOTER: CSSProperties = {
  display: "flex",
  alignItems: "center",
  gap: 8,
  fontSize: 12,
  color: "var(--cv-muted, rgba(127,127,127,0.9))",
};

export default componentEntry<Props>({
  id: "agent-pane.turn-cost",
  title: "Turn cost at the reply's end: tooltip row, inline, or chip",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/conversation/TurnRows.tsx", "agent-session/acpmux/conversation/turnTokensModel.ts"],
  widths: { narrow: 320, normal: 760 },
  load: async () =>
    function TurnCost({ look, turns }: Props) {
      return (
        <div style={{ display: "flex", flexDirection: "column", alignItems: "flex-start", gap: 20, padding: 24 }}>
          {turns.map(({ worked, cost }) => (
            <div
              key={worked}
              data-gallery-turn-cost={look}
              style={{ display: "flex", flexDirection: "column", gap: 8 }}
            >
              <div style={FOOTER}>
                <span>Copy</span>
                <span>Retry</span>
                {look === "inline" && cost && <span title={detail(cost)}>{usd(total(cost))}</span>}
                {look === "chip" && cost && (
                  <span
                    title={detail(cost)}
                    style={{ padding: "1px 6px", borderRadius: 999, border: "1px solid currentColor", opacity: 0.85 }}
                  >
                    {usd(total(cost))}
                  </span>
                )}
              </div>
              {look === "tooltip-row" && (
                <div className="ui-title-tooltip ui-glass" style={{ position: "static" }}>
                  {[`Worked for ${worked}`, "Output 5.1K", ...(cost ? [detail(cost)] : [])].join("\n")}
                </div>
              )}
              {look !== "tooltip-row" && cost && (
                <div className="ui-title-tooltip ui-glass" style={{ position: "static" }}>
                  {detail(cost)}
                </div>
              )}
            </div>
          ))}
        </div>
      );
    },
  variants: {
    "tooltip-row": { props: { look: "tooltip-row", turns: TURNS } },
    inline: { props: { look: "inline", turns: TURNS } },
    chip: { props: { look: "chip", turns: TURNS } },
  },
});
