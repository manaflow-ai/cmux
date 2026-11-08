// A run of Claude Code tool calls as the transcript draws them: a commands group holding a call a
// hook blocked, one that failed and one that went on in the background, beside a lone read and a
// lone failed command. All displayed content is synthetic.
import { createRoot } from "react-dom/client";
import type { CSSProperties } from "react";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/glass/glass.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import { ToolRows } from "../../src/agent-session/acpmux/conversation/TurnRows";
import { turnView } from "../../src/agent-session/acpmux/conversation/turns";
import { mixedToolTurnFixture } from "../../src/agent-session/acpmux/conversation/mixedToolRunFixture";
import { ToolGroupRow } from "../../src/agent-session/acpmux/conversation/ToolGroupRow";
import { ToolRow } from "../../src/agent-session/acpmux/conversation/ToolRow";
import { CommandRow } from "../../src/agent-session/acpmux/conversation/CommandRow";
import { ThoughtRow } from "../../src/agent-session/acpmux/conversation/ThoughtRow";
import cmuxExecGallery from "../../src/agent-session/acpmux/conversation/CmuxExecRows.gallery";
import "../../src/agent-session/acpmux/conversation/ToolRowColumn.gallery.css";
import strings from "../../src/agent-session/acpmux/generated/strings.json";
import type { AcpmuxActivity } from "../../src/agent-session/acpmux/model";

globalThis.__cmuxPaneStrings = { en: strings.en };
document.documentElement.dataset.cmuxMotion = "off";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const call = (tool: Partial<Tool> & { id: string }): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { title: "", kind: "execute", status: "completed", startedAt: 1000, endedAt: 3000, ...tool },
});
const CmuxExecGallery = await cmuxExecGallery.load();

const blocked = call({
  id: "blocked",
  status: "failed",
  description: "Merge the reviewed fixture pull request once its checks pass",
  command: "gh pr merge 101 --squash --match-head-commit 0123456789abcdef0123456789abcdef01234567",
  output:
    "PreToolUse:Bash hook error: Blocked: the fixture guard needs a passing review on the head before a merge, so this merge waits for one.",
});
const failed = call({
  id: "failed",
  status: "failed",
  command: "bun test fixture/alpha.test.ts fixture/beta.test.ts fixture/gamma.test.ts --timeout 20000",
  output: "Exit code 1\nerror: expected 3 to be 4 in fixture/alpha.test.ts",
});
const background = call({
  id: "background",
  status: "completed",
  description: "After the fixture window, merge #101 pinned",
  command: "sleep 600 && gh pr merge 101",
  background: { state: "running" },
});
const lone = call({
  id: "lone",
  kind: "read",
  title: "Read fixture/notes.md",
  locations: [{ path: "fixture/notes.md" }],
});
// A program the verb table does not know (commandActions.ts), so the row reads "Ran <command>"
// with the line in mono: the column test measures the space between the verb and the line.
const loneFailed = call({
  id: "lone-failed",
  status: "failed",
  command: "./fixture/decode.sh --input fixture/broken.json",
  output: "Exit code 1\njson.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)",
});

const THOUGHT = "The fixture helper retries every failure the same way, so check how it decides to retry.";
const doneThought: AcpmuxActivity = { kind: "thought", text: THOUGHT, startedAt: 1000, endedAt: 13_400 };
const liveThought: AcpmuxActivity = { kind: "thought", text: THOUGHT };

function App() {
  const params = new URLSearchParams(location.search);
  const theme = params.get("theme") === "light" ? "light" : "dark";
  const width = Number(params.get("width") ?? 760);
  const look = params.get("look");
  const working = params.get("working") === "1";
  const projected =
    params.get("fixture") === "mixed"
      ? turnView(mixedToolTurnFixture(working), new Set(["worked-mixed-prompt"]), {
          agentFamily: params.get("harness") ?? "claude",
          working,
        }).find((row) => row.kind === "activity")
      : undefined;
  if (look) document.documentElement.dataset.toolStepsLook = look;
  if (params.get("fixture") === "script") return <CmuxExecGallery look="after" mode={theme} />;
  return (
    <main
      className="acpmux-shell"
      data-theme={theme}
      style={
        {
          "--agent-page-bg": theme === "dark" ? "#202124" : "#f7f7f2",
          "--agent-text": theme === "dark" ? "#f5f5f1" : "#242420",
          "--font-ui": "system-ui",
          width: `${width}px`,
          padding: "24px",
          boxSizing: "border-box",
        } as CSSProperties
      }
    >
      {projected && (
        <div data-fixture-mixed>
          <ToolRows row={projected} sessionId="mixed-fixture" />
        </div>
      )}
      <div className="acpmux-row" style={{ position: "relative", left: 0, right: 0, width: "100%" }}>
        <div className="cv-tools" data-fixture-column>
          <ToolRow item={lone} />
          <ToolGroupRow kind="commands" items={[blocked, failed, background]} disclosureKey="fixture-group" />
          <CommandRow item={loneFailed} />
          <CommandRow item={{ ...blocked, tool: { ...blocked.tool!, id: "blocked-lone", description: undefined } }} />
        </div>
      </div>
      <div className="acpmux-row" style={{ position: "relative", left: 0, right: 0, width: "100%" }}>
        <div data-fixture-thoughts>
          <div data-thought>
            <ThoughtRow id="fixture-thought" item={doneThought} />
          </div>
          <div data-thought>
            <ThoughtRow id="fixture-live-thought" item={liveThought} streaming />
          </div>
        </div>
      </div>
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
