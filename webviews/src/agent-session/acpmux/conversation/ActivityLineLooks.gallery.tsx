// l10n-allow-file: gallery fixture labels, not shipped UI.
// Three visual arms for the running activity line: the current unmarked line, a generic spinner
// for every row, and a kind-aware mark (the shipped choice) that keeps command identity visible.
import { componentEntry } from "../../../gallery/format";
import { Spinner, TerminalSquare } from "./icons";

type Look = "none" | "spinner" | "kind";

function ActivityLineLooks({ look }: { look: Look }) {
  const rows = [
    { text: "Edit ProductGrid.module.css", command: false, time: "26s" },
    { text: "Run bun test src/fetch", command: true, time: "31s" },
  ];
  return (
    <div className="acpmux-shell cv-activity-line-looks" data-look={look}>
      <div className="cv-activity-line-looks__title">Running activity line</div>
      <div className="cv-activity-line-looks__rows">
        {rows.map((row) => (
          <div key={row.text} className="cv-activity cv-tool">
            {look !== "none" && (
              <span className="cv-tool__icon" aria-hidden="true">
                {look === "kind" && row.command ? <TerminalSquare /> : <Spinner size={16} />}
              </span>
            )}
            <span className="cv-activity__label">{row.text}</span>
            <span className="cv-activity__time">{row.time}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

export default componentEntry<{ look: Look }>({
  id: "agent-pane.activity-line-looks",
  title: "Running activity line: icon alignment",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 420, normal: 640, wide: 820 },
  covers: ["agent-session/acpmux/conversation/ActivityLine.tsx"],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css"), import("./ActivityLineLooks.gallery.css")]),
  load: async () => ActivityLineLooks,
  variants: {
    none: {
      note: "Before: the live line starts at the pane edge, unlike every tool and status row.",
      props: { look: "none" },
    },
    spinner: {
      note: "Arm 2: a shared working spinner marks both rows, matching the live state but hiding command identity.",
      props: { look: "spinner" },
    },
    kind: {
      note: "Chosen: generic work keeps the spinner while a running command uses the terminal mark, preserving the shared icon column and tool identity.",
      props: { look: "kind" },
    },
  },
});
