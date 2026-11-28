// l10n-allow-file: gallery fixture (sample commands, test names, messages), not shipped UI.
// An agent's test command as a live pass/fail panel (wow idea 12, "Live test results"; Leo,
// 2026-11-28: "you might as well just go for broke. say 20."). The counts and failures are read in
// Rust as the output streams (acpmux hub/tool_test_results.rs); the looks compared:
// - `strip` (chosen, shipped): a card under the row, the counts ticking, each failure a line with
//   its name, a chip opening the file at its line, and the first words of why.
// - `bar`: the same card with a thin proportion bar of passed, failed and skipped under the counts.
// - `running`: the chosen look mid-run, counts still ticking and the first failure in.
// - `waiting`: the chosen look before the first test reports.
// - `before`: the row as it was, the counts only in the folded output.
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { tool } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxTestResults } from "../model";
import { ToolGroupRow } from "./ToolGroupRow";
import { TestResultsPanel, type TestResultsLook } from "./TestResultsPanel";
import { TranscriptDisclosureProvider } from "./transcriptDisclosure";

type Look = TestResultsLook | "running" | "waiting" | "before";
type Props = { look: Look };

const failures: AcpmuxTestResults["failures"] = [
  {
    name: "hub::tool_paths::tests::a_moved_file_keeps_its_line",
    path: "cmux-tui/crates/acpmux/src/hub/tool_paths.rs",
    line: 418,
    message: "assertion `left == right` failed: left: 417, right: 418",
  },
  {
    name: "store::replay::resumes_after_a_cut",
    path: "cmux-tui/crates/acpmux/src/store/replay.rs",
    line: 92,
    message: "called `Option::unwrap()` on a `None` value",
  },
];

const done: AcpmuxTestResults = { runner: "cargo", passed: 412, failed: 2, skipped: 3, done: true, failures };
const running: AcpmuxTestResults = {
  runner: "cargo",
  passed: 187,
  failed: 1,
  skipped: 1,
  done: false,
  failures: failures.slice(0, 1),
};
const waiting: AcpmuxTestResults = { runner: "cargo", passed: 0, failed: 0, skipped: 0, done: false, failures: [] };

const command = "cargo test -p acpmux";
const output = "running 417 tests\n...\ntest result: FAILED. 412 passed; 2 failed; 3 ignored\n";

function TestResultsGallery({ look }: Props) {
  const results = look === "running" ? running : look === "waiting" ? waiting : done;
  const status = look === "running" || look === "waiting" ? "in_progress" : "failed";
  const row = tool(command, "execute", status, {
    command,
    output: look === "waiting" ? "" : output,
    ...(look === "before" ? {} : { testResults: results }),
  });
  return (
    <TranscriptDisclosureProvider sessionId={`gallery-test-results-${look}`}>
      <main className="acpmux-conversation">
        <div className="acpmux-row">
          {look === "bar" ? (
            <>
              <ToolGroupRow
                kind="commands"
                items={[{ ...row, tool: { ...row.tool!, testResults: undefined } }]}
                disclosureKey="bar"
              />
              <TestResultsPanel results={done} look="bar" />
            </>
          ) : (
            <ToolGroupRow kind="commands" items={[row]} disclosureKey={look} />
          )}
        </div>
      </main>
    </TranscriptDisclosureProvider>
  );
}

const variant = (look: Look, note: string): ComponentVariant<Props> => ({ note, props: { look } });

export default componentEntry<Props>({
  id: "agent-pane.test-results-panel",
  title: "A test command's live pass/fail panel",
  area: "Agent pane",
  pane: true,
  height: 300,
  widths: { narrow: 420, normal: 640, wide: 900 },
  covers: [
    "agent-session/acpmux/conversation/TestResultsPanel.tsx",
    "agent-session/acpmux/conversation/CommandRow.tsx",
  ],
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./TestResultsPanel.gallery.css")]),
  load: async () => TestResultsGallery,
  keywords: ["test", "results", "passed", "failed", "cargo", "pytest", "jest", "live", "panel"],
  variants: {
    strip: variant("strip", "Chosen: counts and a line per failure with a chip opening the file at its line."),
    bar: variant("bar", "The same card with a thin passed/failed/skipped proportion bar."),
    running: variant("running", "Chosen look mid-run: the counts tick and the first failure is in."),
    waiting: variant("waiting", "Chosen look before the first test reports."),
    before: variant("before", "Before: the counts only in the folded output."),
  },
});
