// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { AutoReserveControl } from "./AutoReserveControl";
import type { AutoReserveState } from "./autoReserveModel";

type Props = { reserve: AutoReserveState };

const AT = Date.UTC(2026, 10, 24, 11, 2, 0);
const MOVED = { title: "Port the settings page", reason: "cpu", atMs: AT, state: "moved" } as const;

const reserve = (state: AutoReserveState): Props => ({ reserve: state });

export function AutoReserveGallery({ reserve: initial }: Props) {
  const [state, setState] = useState(initial);
  const clearMove = () => setState((current) => ({ ...current, lastMove: undefined }));
  return (
    <AutoReserveControl
      reserve={state}
      onChange={(next) => setState((current) => ({ ...current, ...next }))}
      onBringBack={clearMove}
      onCancel={clearMove}
    />
  );
}

export default componentEntry<Props>({
  id: "agent-pane.auto-reserve",
  title: "Auto: Keep for me, last move (RFD 0072 piece 6)",
  area: "Agent pane",
  covers: ["agent-session/acpmux/place/AutoReserveControl.tsx#AutoReserveControl"],
  pane: true,
  load: async () => AutoReserveGallery,
  widths: { narrow: 360, normal: 640, wide: 900 },
  height: 180,
  variants: {
    off: {
      note: "Auto off (the default): the switch and the slider dimmed, no last-move line.",
      props: reserve({ on: false, keep: 0.5 }),
    },
    "keep-50-none": {
      note: "On at the default 50%: the slider's four stops, and one line saying nothing moved yet.",
      props: reserve({ on: true, keep: 0.5 }),
    },
    "keep-25-moved": {
      note: "On at 25%, after a move: the last move and its reason in one line (the chat carries the chip), Bring Back one click away.",
      props: reserve({ on: true, keep: 0.25, lastMove: MOVED }),
    },
    "keep-75-memory": {
      note: "On at 75%, last move for memory: the reason is the only thing that changes in the line.",
      props: reserve({ on: true, keep: 0.75, lastMove: { ...MOVED, reason: "memory" } }),
    },
    moving: {
      note: "A move under way: the line says so and offers Cancel, one click, no dialog.",
      props: reserve({ on: true, keep: 0.5, lastMove: { ...MOVED, state: "moving" } }),
    },
    "pool-80": {
      note: "At 80% of the pool: the control shows it, under the last move.",
      props: reserve({ on: true, keep: 0.5, lastMove: MOVED, pool: 0.8 }),
    },
    ceiling: {
      note: "At the pool's ceiling: Auto says it keeps agents on this Mac, so the reserve is no longer guaranteed.",
      props: reserve({ on: true, keep: 0.5, pool: 1 }),
    },
  },
});
