// l10n-allow-file: synthetic agent names and messages, not shipped UI.
// The clickable agent-session chip on every transcript row that names a chat (session-chip-browser.test.ts):
// a received message's sender, a sent message's recipient (an `acpmux send` and a SendMessage), and
// a started chat's name in a reply. Every name here is synthetic.
import { createRoot } from "react-dom/client";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/glass/glass.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import { IncomingMessageLine } from "../../src/agent-session/acpmux/conversation/IncomingMessageCard";
import { AcpmuxSendLine } from "../../src/agent-session/acpmux/conversation/SentMessageLine";
import { acpmuxSendCall } from "../../src/agent-session/acpmux/conversation/acpmuxSends";
import { StartedSessionChip } from "../../src/agent-session/acpmux/started/StartedSessionCard";
import { SubsessionContext, SubsessionStore } from "../../src/agent-session/acpmux/subagents/subsessions";
import strings from "../../src/agent-session/acpmux/generated/strings.json";
import type { AcpmuxActivity } from "../../src/agent-session/acpmux/model";
import type { AcpmuxSessionEntry } from "../../src/agent-session/acpmux/sessionList";

globalThis.__cmuxPaneStrings = { en: strings.en };
document.documentElement.dataset.cmuxMotion = "off";
const requested = new URLSearchParams(location.search).get("theme");
const theme = requested === "light" || requested === "mocha" ? requested : "dark";
// The pane's theme colours, as the host's theme sets them (transcript-glyph-alignment.harness.tsx).
// `mocha` is Catppuccin Mocha's palette, a theme whose own bright blue (ANSI 12) is set, so a chip
// that still took the link blue would show it.
const themes = {
  dark: { scheme: "dark", page: "#202124", text: "#f5f5f1", muted: "#c9c9c4", soft: "#95958f", blue: "" },
  light: { scheme: "light", page: "#f7f7f2", text: "#242420", muted: "#55554f", soft: "#77776f", blue: "" },
  mocha: { scheme: "dark", page: "#1e1e2e", text: "#cdd6f4", muted: "#bac2de", soft: "#a6adc8", blue: "#89b4fa" },
} as const;
for (const [key, value] of Object.entries({
  "--agent-page-bg": themes[theme].page,
  "--agent-text": themes[theme].text,
  "--agent-muted": themes[theme].muted,
  "--agent-soft": themes[theme].soft,
  "--agent-ansi-12": themes[theme].blue,
  "--font-ui": "system-ui",
}))
  if (value) document.documentElement.style.setProperty(key, value);
// Prose links take their own blue for the scheme (styles.css `--agent-link-base: light-dark(...)`);
// the session chip takes the theme's text tokens.
document.documentElement.style.colorScheme = themes[theme].scheme;
document.body.style.background = themes[theme].page;
document.body.style.margin = "0";

const entry = (fields: Partial<AcpmuxSessionEntry> & { sessionId: string }) =>
  ({ displayTitle: fields.name ?? "", pendingPermissions: 0, ...fields }) as AcpmuxSessionEntry;
const store = new SubsessionStore();
store.set([
  entry({ sessionId: "mux-lane", name: "lane-host-1/tabs-panes-r2", peer: "lane-host-1", harness: "claude" }),
  entry({ sessionId: "mux-deputy", name: "coord-deputy", hostKind: "local", harness: "codex" }),
]);
const opened: string[] = [];
(window as unknown as { opened: string[] }).opened = opened;
const open = (id: string) => void opened.push(id);

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const shellSend: Tool = {
  id: "toolu_shell",
  title: "acpmux send",
  kind: "execute",
  status: "completed",
  command: "acpmux send --no-wait coord-deputy 'The batch is next; start with the sidebar.'",
  output: "queued",
};

function App() {
  return (
    <main
      className="acpmux-shell"
      data-theme={themes[theme].scheme}
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "stretch",
        padding: 24,
        width: 640,
        height: "auto",
      }}
    >
      <SubsessionContext.Provider value={{ store, open }}>
        <div data-chip-row="received">
          <IncomingMessageLine
            id="chip-received"
            message={{
              name: "lane-host-1/tabs-panes-r2",
              text: "#29801 is up; the tab strip keeps its suffixes now.",
              raw: "[lane-host-1/tabs-panes-r2] #29801 is up; the tab strip keeps its suffixes now.",
            }}
            onOpen={open}
          />
        </div>
        <div data-chip-row="received-plain">
          <IncomingMessageLine
            id="chip-received-plain"
            message={{ name: "gone-lane", text: "Done here.", raw: "[gone-lane] Done here." }}
            onOpen={open}
          />
        </div>
        <div data-chip-row="sent">
          <AcpmuxSendLine tool={shellSend} send={acpmuxSendCall(shellSend)!} />
        </div>
        <p className="cv-md" data-chip-row="reply">
          Started{" "}
          <StartedSessionChip
            mention={{ sessionId: "mux-lane", text: "tabs-panes-r2", title: "tabs-panes-r2", state: "running" }}
            text="tabs-panes-r2"
            onOpen={open}
          />{" "}
          for the tab strip.
        </p>
      </SubsessionContext.Provider>
    </main>
  );
}
createRoot(document.getElementById("root")!).render(<App />);
