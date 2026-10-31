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
import { ToolGroupRow } from "../../src/agent-session/acpmux/conversation/ToolGroupRow";
import { ToolRow } from "../../src/agent-session/acpmux/conversation/ToolRow";
import { CommandRow } from "../../src/agent-session/acpmux/conversation/CommandRow";
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
const loneFailed = call({
  id: "lone-failed",
  status: "failed",
  command: "python3 fixture/decode.py --input fixture/broken.json",
  output: "Exit code 1\njson.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)",
});

function App() {
  const params = new URLSearchParams(location.search);
  const theme = params.get("theme") === "light" ? "light" : "dark";
  const width = Number(params.get("width") ?? 760);
  const look = params.get("look");
  if (look) document.documentElement.dataset.toolStepsLook = look;
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
      <div className="cv-tools" data-fixture-column>
        <ToolRow item={lone} />
        <ToolGroupRow kind="commands" items={[blocked, failed, background]} disclosureKey="fixture-group" />
        <CommandRow item={loneFailed} />
        <CommandRow item={{ ...blocked, tool: { ...blocked.tool!, id: "blocked-lone", description: undefined } }} />
      </div>
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
