// The VM's size rows in the chat (cmuxterm-hq RFD 0133, items 1, 2 and 9): the warning before or
// during a job too big for the machine (Resize now, or the plan's upgrade; Run it on a build machine;
// Carry on), and AutoSize's notice after the machine grew, shrank or was held at the plan's limit.
// Every row here is what acpmux's `resize_row.rs` sends: its test writes resizeRow.fixtures.json.
import { componentEntry } from "../../../gallery/format";
import fixtures from "./resizeRow.fixtures.json";
import type { AutoSizeRow, WarningRow } from "./resizeRow";
import type { ResizeRowLook } from "./ResizeRow";

type Props = { row: keyof typeof fixtures; look: ResizeRowLook };

const noop = () => undefined;

export default componentEntry<Props>({
  id: "agent-pane.resize-row",
  title: "VM size rows",
  area: "Agent pane",
  pane: true,
  height: 200,
  widths: { narrow: 360, normal: 520, wide: 720 },
  covers: ["agent-session/acpmux/conversation/ResizeRow.tsx", "agent-session/acpmux/conversation/resizeRow.ts"],
  keywords: ["resize", "autosize", "vm", "upgrade", "build machine", "chromium", "memory"],
  load: async () => {
    const { ResizeRow } = await import("./ResizeRow");
    return function GalleryResizeRow({ row, look }: Props) {
      return (
        <div style={{ padding: "16px 16px 0" }}>
          <ResizeRow row={fixtures[row] as unknown as WarningRow | AutoSizeRow} look={look} onAction={noop} />
        </div>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    "chromium-card": {
      note: "`fetch chromium` on the default 2 vCPU / 4 GiB VM: the RFD's sentence, Resize now to 16 / 32, Run it on a build machine, Carry on.",
      props: { row: "chromium", look: "card" },
    },
    "chromium-rail": { note: "The same warning, the quieter rail arm.", props: { row: "chromium", look: "rail" } },
    "chromium-line": { note: "The same warning, one line and the buttons.", props: { row: "chromium", look: "line" } },
    "chromium-on-plus": {
      note: "On Plus (4 / 16) the ceiling is in the way: the first button reads Upgrade to Pro for 8 vCPU / 32 GiB.",
      props: { row: "chromiumOnPlus", look: "card" },
    },
    llvm: {
      note: "An LLVM configure short of disk, on Pro: Resize now to Pro's 8 / 32.",
      props: { row: "llvm", look: "card" },
    },
    "big-checkout": {
      note: "`cargo build` in a 40 GiB checkout with 3 GiB free: bigger than free memory x 8.",
      props: { row: "bigCheckout", look: "card" },
    },
    pressure: {
      note: "During a job: 3.8 of 4 GiB in use, 2 vCPU busy for 6 minutes.",
      props: { row: "pressure", look: "card" },
    },
    grew: {
      note: "AutoSize grew the machine for memory: the rate and Undo at next pause.",
      props: { row: "grew", look: "rail" },
    },
    "grew-cpu": { note: "AutoSize grew the machine for busy CPUs.", props: { row: "grewCpu", look: "rail" } },
    held: {
      note: "AutoSize held at Plus's limit: the upgrade to Pro is the button.",
      props: { row: "held", look: "card" },
    },
    shrank: { note: "AutoSize went back to 2 / 4 when idle.", props: { row: "shrank", look: "line" } },
  },
});
