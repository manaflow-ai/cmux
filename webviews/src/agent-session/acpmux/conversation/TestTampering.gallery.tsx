// l10n-allow-file: gallery fixtures (synthetic test edits), not shipped UI.
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import type { AcpmuxRow } from "../model";
import { TestTampering } from "./TestTampering";

type Props = { rows: readonly AcpmuxRow[] };

const finding = {
  kind: "weakened-assertion",
  line: 18,
  message: "An exact assertion was replaced with a truthiness check.",
  old: "expect(response.status).toEqual(401)",
  new: "expect(response.status).toBeTruthy()",
};

const rows = (files: { path: string; findings: (typeof finding)[] }[], id = "turn-tampering"): readonly AcpmuxRow[] => [
  {
    id,
    version: 1,
    at: 1,
    kind: "activity",
    items: [
      {
        kind: "tool",
        text: "Edit tests",
        tool: {
          id: "edit-tests",
          title: "Edit tests",
          kind: "edit",
          status: "completed",
          tampering: { count: files.reduce((total, file) => total + file.findings.length, 0), files },
        },
      },
    ],
  },
];

const variants: Record<string, ComponentVariant<Props>> = {
  compact: {
    note: "A single red disclosure stays compact until the reader opens the evidence.",
    props: { rows: rows([{ path: "tests/auth.test.ts", findings: [finding] }], "turn-tampering-compact") },
  },
  expanded: {
    note: "Expanded evidence shows the exact file, line, old assertion and replacement with Restore and Ask why.",
    props: { rows: rows([{ path: "tests/auth.test.ts", findings: [finding] }], "turn-tampering-expanded") },
    play: async ({ click, waitFor, document }) => {
      await waitFor(() => document.querySelector(".acpmux-tampering-head"));
      await click({ selector: ".acpmux-tampering-head" });
      await waitFor(() => document.querySelector(".acpmux-tampering-evidence-title"));
    },
  },
  multiFile: {
    note: "Multiple findings stay grouped in one turn disclosure and keep each path visible.",
    props: {
      rows: rows(
        [
          { path: "tests/auth.test.ts", findings: [finding] },
          {
            path: "crates/api/tests/auth.rs",
            findings: [
              {
                ...finding,
                kind: "removed-assertion",
                line: 32,
                message: "An assertion was removed while the test remained.",
              },
            ],
          },
        ],
        "turn-tampering-multi",
      ),
    },
  },
};

export default componentEntry<Props>({
  id: "agent-pane.test-tampering",
  title: "Test tampering alarm",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: ["agent-session/acpmux/conversation/TestTampering.tsx#TestTampering"],
  styles: () => import("../styles.css"),
  load: async () => TestTampering,
  variants,
});
