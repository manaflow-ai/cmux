// l10n-allow-file: gallery fixtures (sample commands and sub-session names), not shipped UI.
// A sub-session's ask in the chat above it (ChildAsk.tsx; cmuxterm-hq#7794 #7: a subagent's ask
// showed only in its own chat, so the run stalled where nobody looked). The card is the chat's own
// permission card, keys included; what is new is how it names the sub-session that asked. Three looks:
// - line (shipped): the asks stack's quiet line, "Sub-session · tests", with Open, over the card, as a
//   pinned question reads ("Needs your input" with Dismiss), so the stack reads as one family.
// - chip: the name as a small pill over the card, and no Open (the tray opens it).
// - foot: the card first, then the line with Open under it.
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxPermission } from "../model";
import { ChildAsk } from "./ChildAsk";
import type { ChildAsk as ChildAskModel } from "./childAsks";

type Look = "line" | "chip" | "foot";
type Props = { look: Look; deep?: boolean; more?: number };

const permission = {
  permissionId: "gallery-child-ask",
  pending: true,
  title: "Run make test",
  kind: "execute",
  command: "make test",
  options: [
    { id: "allow", name: "Allow", kind: "allow_once", allow: true },
    { id: "always", name: "Always allow", kind: "allow_always", allow: true },
    { id: "deny", name: "Deny", kind: "reject_once", allow: false },
  ],
} as unknown as AcpmuxPermission;

const looks: Record<Exclude<Look, "line">, string> = {
  chip: `
    [data-child-ask-look="chip"] .acpmux-pending-ask__head { justify-content: flex-start; }
    [data-child-ask-look="chip"] .acpmux-pending-ask__label { padding: 0 8px; border-radius: 999px;
      background: color-mix(in srgb, var(--agent-text) 8%, transparent); color: var(--agent-soft); }
    [data-child-ask-look="chip"] .acpmux-pending-ask__dismiss { display: none; }`,
  foot: `
    [data-child-ask-look="foot"] .acpmux-pending-ask { flex-direction: column-reverse; }`,
};

function ChildAskInPane({ look, deep = false, more = 0 }: Props) {
  const child: ChildAskModel = {
    ask: { sessionId: deep ? "lint" : "tests", permission, at: 1 },
    name: deep ? "lint" : "tests",
    direct: !deep,
    harness: "claude",
  };
  return (
    <div
      className="acpmux-shell"
      data-child-ask-look={look}
      style={{ flexDirection: "column", justifyContent: "flex-end", gap: 12, padding: 16 }}
    >
      {look !== "line" && <style>{looks[look]}</style>}
      <p style={{ margin: 0, color: "var(--agent-text)" }}>Started a sub-session to run the tests; I'll wait for it.</p>
      <div className="acpmux-permission acpmux-asks-stack" style={{ padding: 0 }}>
        <ChildAsk child={child} waiting={more} shortcuts onOpen={() => undefined} />
      </div>
    </div>
  );
}

const variant = (look: Look, note: string, extra: Partial<Props> = {}) => ({ note, props: { look, ...extra } });

export default componentEntry({
  id: "agent-pane.child-ask",
  title: "Agent pane: a sub-session's ask in the chat above it",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 420, normal: 640, wide: 900 },
  anchors: [{ selector: ".acpmux-pending-ask" }],
  covers: ["agent-session/acpmux/subagents/ChildAsk.tsx#ChildAsk"],
  styles: () =>
    Promise.all([import("../styles.css"), import("../bottomStack.css"), import("../conversation/PendingAsks.css")]),
  load: async () => ChildAskInPane,
  variants: {
    line: variant(
      "line",
      "Shipped: the stack's quiet line names the sub-session, with Open, over the chat's own card.",
    ),
    "line-deep": variant("line", "Shipped: a grandchild's ask reads Related · its name.", { deep: true }),
    "line-more": variant("line", "Shipped: two more asks below wait behind this one.", { more: 2 }),
    chip: variant("chip", "Alternative: the name as a pill over the card, no Open."),
    foot: variant("foot", "Alternative: the card first, the line with Open under it."),
  },
});
