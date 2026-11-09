// l10n-allow-file: deterministic gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { TripwireRecap, TripwireStatus, type Tripwire, type TripwireLook } from "./TripwireStatus";

const allGreen: Tripwire[] = [
  {
    name: "Login shows an error",
    path: "tests/login.test.ts",
    verdict: "backed",
    toolCallId: "t1",
    command: "bun test tests/login.test.ts",
  },
  {
    name: "Wrong password is rejected",
    path: "tests/auth.test.ts",
    verdict: "backed",
    toolCallId: "t2",
    command: "bun test tests/auth.test.ts",
  },
  {
    name: "Claim checks are backed",
    path: "src/agent-session/acpmux/claimChecks.test.tsx",
    verdict: "backed",
    toolCallId: "t3",
    command: "bun test src/agent-session/acpmux/claimChecks.test.tsx",
  },
];
const oneRed: Tripwire[] = [...allGreen.slice(0, 1), { ...allGreen[1]!, verdict: "failed" }, allGreen[2]!];
const neverRun: Tripwire[] = allGreen.map((item) => ({ ...item, verdict: "none", toolCallId: undefined }));

type GalleryProps = { state: "green" | "red" | "none"; look: TripwireLook };

function Gallery({ state, look }: GalleryProps) {
  const items = state === "green" ? allGreen : state === "red" ? oneRed : neverRun;
  return (
    <div style={{ display: "grid", gap: 12, padding: 16, maxWidth: 760 }}>
      <div className="acpmux-handoff-header-tools" style={{ width: "100%" }}>
        <div className="acpmux-tripwire-header-slot">
          {look === "rows" ? (
            <TripwireRecap items={items} look={look} onShowCall={() => true} />
          ) : (
            <TripwireStatus items={items} look={look} onShowCall={() => true} />
          )}
        </div>
      </div>
    </div>
  );
}

export default componentEntry<{ state: "green" | "red" | "none"; look: TripwireLook }>({
  id: "agent-pane.tripwire-status",
  title: "Plan tripwires",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 420, normal: 680, wide: 960 },
  covers: ["agent-session/acpmux/tripwires/TripwireStatus.tsx#TripwireStatus"],
  styles: () => import("../styles.css"),
  load: async () => Gallery,
  variants: {
    "green-dots": {
      note: "Selected: compact dots show every promised check backed by a run.",
      props: { state: "green", look: "dots" },
    },
    "red-dots": {
      note: "A failed check stays visible in red; the strip never claims completion.",
      props: { state: "red", look: "dots" },
    },
    "never-run": {
      note: "Dashed grey dots make unrun checks distinct from a passing run.",
      props: { state: "none", look: "dots" },
    },
    underline: {
      note: "Alternative: the name underline carries the verdict without adding a badge.",
      props: { state: "red", look: "underline" },
    },
    rows: { note: "Alternative recap: two quiet rows expose each test path.", props: { state: "red", look: "rows" } },
  },
});
