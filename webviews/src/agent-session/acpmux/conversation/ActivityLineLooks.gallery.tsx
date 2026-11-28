// l10n-allow-file: gallery fixture labels, not shipped UI.
// Four visual arms for the running activity line: the current unmarked line, a generic spinner,
// a mixed spinner/kind treatment, and the aligned treatment that keeps the shared icon column
// without adding a second working-state mark.
import { componentEntry } from "../../../gallery/format";
import { Spinner, TerminalSquare } from "./icons";

type Look = "none" | "spinner" | "kind" | "aligned";

function Mark({ look, command }: { look: Look; command: boolean }) {
  if (look === "aligned") return command ? <TerminalSquare /> : null;
  if (look === "kind" && command) return <TerminalSquare />;
  return <Spinner size={16} />;
}

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
                <Mark look={look} command={row.command} />
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
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./ActivityLineLooks.gallery.css")]),
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
      note: "Arm 3: generic work keeps the spinner while a running command uses the terminal mark; rejected because the live line is not a working-state mark.",
      props: { look: "kind" },
    },
    aligned: {
      note: "Chosen: every line reserves the shared icon slot; plan work leaves it empty and a running command uses only its static terminal mark.",
      props: { look: "aligned" },
    },
  },
});
