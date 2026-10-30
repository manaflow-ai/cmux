// l10n-allow-file: public gallery and browser-test fixture, not shipped UI.
import type { AcpmuxRow } from "../model";

export const GAP_KINDS = ["tool", "prompt", "agent"] as const;
export type GapKind = (typeof GAP_KINDS)[number];

export function gapRow(kind: GapKind, id: string, at: number): AcpmuxRow {
  const text = `${id} keeper checks the lantern, records the rising tide, and leaves the harbour ready for the next watch.`;
  if (kind === "tool")
    return {
      id,
      version: 1,
      at,
      kind: "activity",
      settled: true,
      items: [
        {
          kind: "tool",
          text: `Read ${id}`,
          tool: { id: `${id}-call`, kind: "read", title: `Read ${id}`, status: "completed", output: text },
        },
      ],
    };
  return { id, version: 1, at, kind: kind === "prompt" ? "user" : "assistant", text };
}

export function gapPair(above: GapKind, below: GapKind): AcpmuxRow[] {
  return [
    gapRow("agent", "before", 1_000),
    gapRow(above, "upper", 2_000),
    gapRow(below, "lower", 3_000),
    gapRow("agent", "after", 4_000),
  ];
}
