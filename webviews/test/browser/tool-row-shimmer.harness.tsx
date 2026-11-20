// Running tool rows beside finished ones, as the transcript draws them: a call that went on in the
// background ("Monitor", the row Leo showed), a foreground read still running, a running command,
// and a finished read and command. `?motion=` sets the app's motion gate. All content is synthetic.
import { createRoot } from "react-dom/client";
import type { CSSProperties } from "react";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/glass/glass.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import { ToolRow } from "../../src/agent-session/acpmux/conversation/ToolRow";
import { CommandRow } from "../../src/agent-session/acpmux/conversation/CommandRow";
import strings from "../../src/agent-session/acpmux/generated/strings.json";
import type { AcpmuxActivity } from "../../src/agent-session/acpmux/model";

globalThis.__cmuxPaneStrings = { en: strings.en };
const params = new URLSearchParams(location.search);
const motion = params.get("motion");
if (motion) document.documentElement.dataset.cmuxMotion = motion;

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const call = (tool: Partial<Tool> & { id: string }): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { title: "", kind: "other", status: "completed", startedAt: 1000, endedAt: 3000, ...tool },
});

const rows = [
  { state: "running", item: call({ id: "monitor", title: "Monitor", background: { state: "running" } }) },
  {
    state: "running",
    item: call({ id: "read", kind: "read", title: "Read fixture/notes.md", status: "in_progress", endedAt: undefined }),
  },
  {
    state: "running",
    item: call({
      id: "command",
      kind: "execute",
      command: "bun test fixture",
      status: "in_progress",
      endedAt: undefined,
    }),
  },
  { state: "done", item: call({ id: "done-read", kind: "read", title: "Read fixture/done.md" }) },
  { state: "done", item: call({ id: "done-command", kind: "execute", command: "bun run fixture" }) },
] as const;

function App() {
  return (
    <main
      className="acpmux-shell"
      data-theme="dark"
      style={
        {
          "--agent-page-bg": "#202124",
          "--agent-text": "#f5f5f1",
          "--font-ui": "system-ui",
          width: "760px",
          padding: "24px",
          boxSizing: "border-box",
        } as CSSProperties
      }
    >
      <div className="acpmux-row" style={{ position: "relative", width: "100%" }}>
        <div className="cv-tools" data-fixture-column>
          {rows.map(({ state, item }) => (
            <div key={item.tool!.id} data-fixture-state={state}>
              {item.tool!.command ? <CommandRow item={item} /> : <ToolRow item={item} />}
            </div>
          ))}
        </div>
      </div>
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
