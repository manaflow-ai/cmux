// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { SleepHandoffNote } from "./sleepHandoffNote";

/// `line` is the shipped design (design/sleep-handoff.md): one quiet line in the host line's shape.
/// `stacked` (the reason on its own muted row) and `boxed` (a framed card like the reference banner)
/// are the alternatives it was picked over.
type Layout = "line" | "stacked" | "boxed";
type Props = { note: SleepHandoffNote | undefined; canOpen?: boolean; layout?: Layout };

const MOVED: SleepHandoffNote = { kind: "moved", machine: "gcp-mini-3", routed: "gcp-mini-3/s-1" };
const RUNNING: SleepHandoffNote = { kind: "running", machine: "gcp-mini-3", from: "Leo's MacBook Pro" };
const RAN: SleepHandoffNote = { kind: "ran", machine: "gcp-mini-3", from: "Leo's MacBook Pro" };
const STAYED: SleepHandoffNote = {
  kind: "stayed",
  why: "its uncommitted .env (.env file: it may hold secrets, so it is shared only on purpose) can't go with it",
};

export default componentEntry<Props>({
  id: "agent-pane.sleep-handoff",
  title: "Chat moved when the Mac slept",
  area: "Agent pane",
  pane: true,
  height: 110,
  widths: { narrow: 320, normal: 720, wide: 900 },
  covers: ["agent-session/acpmux/SleepHandoffNotice.tsx"],
  load: async () => {
    const { SleepHandoffNotice } = await import("./SleepHandoffNotice");
    const { NoticeSlot } = await import("./NoticeSlot");
    return function GallerySleepHandoff({ note, canOpen = true, layout = "line" }: Props) {
      if (layout !== "line") return <Alternative note={note} layout={layout} />;
      return (
        <div className="acpmux-shell">
          <NoticeSlot>
            <SleepHandoffNotice note={note} canOpen={canOpen} onOpen={() => undefined} />
          </NoticeSlot>
        </div>
      );
    };
  },
  styles: () => import("./styles.css"),
  variants: {
    "moved-picked": { props: { note: MOVED } },
    "moved-not-listed-yet": { props: { note: MOVED, canOpen: false } },
    "still-running-there": { props: { note: RUNNING } },
    "ran-there": { props: { note: RAN } },
    "running-seen-there": { props: { note: { kind: "running", machine: undefined, from: "Leo's MacBook Pro" } } },
    stayed: { props: { note: STAYED } },
    "moved-alt-stacked": { props: { note: MOVED, layout: "stacked" } },
    "stayed-alt-stacked": { props: { note: STAYED, layout: "stacked" } },
    "moved-alt-boxed": { props: { note: MOVED, layout: "boxed" } },
    cleared: { props: { note: undefined } },
  },
});

/// The alternatives, drawn here only: the shipped component has one layout.
function Alternative({ note, layout }: { note: SleepHandoffNote | undefined; layout: Exclude<Layout, "line"> }) {
  if (!note) return <div className="acpmux-shell" />;
  const [head, detail] =
    note.kind === "moved"
      ? [`Moved to ${note.machine}`, "This Mac went to sleep, so the turn kept going there."]
      : note.kind === "stayed"
        ? ["Stayed on this Mac when it went to sleep", note.why]
        : [`On ${note.machine ?? "this machine"}`, `Moved from ${note.from} when it went to sleep.`];
  const open = note.kind === "moved" && (
    <button type="button" className="acpmux-host-line-quiet">
      Open
    </button>
  );
  if (layout === "stacked")
    return (
      <div className="acpmux-shell">
        <output className="acpmux-host-line-group">
          <div className="acpmux-host-line">
            <p className="acpmux-host-line-message">{head}</p>
            {open}
          </div>
          <div className="acpmux-host-line acpmux-host-line-reassure">
            <p className="acpmux-host-line-note">{detail}</p>
          </div>
        </output>
      </div>
    );
  return (
    <div className="acpmux-shell">
      <output
        className="acpmux-host-line"
        style={{
          border: "1px solid var(--agent-border)",
          borderRadius: "var(--ds-radius-xl)",
          padding: "var(--ds-space-1) var(--ds-space-3)",
        }}
      >
        <p className="acpmux-host-line-message">
          {head}. {detail}
        </p>
        {open}
      </output>
    </div>
  );
}
