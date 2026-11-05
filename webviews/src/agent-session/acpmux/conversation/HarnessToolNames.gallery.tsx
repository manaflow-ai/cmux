// l10n-allow-file: gallery fixture prose, tool names and paths, not shipped copy.
// The same five calls (read a file, search for text, find files, fetch a page, search the web) from
// each harness acpmux runs, drawn by the real rows: one map of every harness's tool names
// (toolNames.ts) reads each as Claude Code's reads (Leo, 2026-11-05: "We have a pretty good
// situation as-is but could we potentially do even better?"). Before it, Gemini's read read
// "src/foo.ts src/foo.ts", its searches as their descriptions, and opencode's and pi's as bare
// "grep", "webfetch". Reference: claude/live/transcript-tool-rows-and-task-list.
import { useEffect } from "react";
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { HARNESS_FIXTURE_CWD, harnessItems, type FixtureHarness } from "../toolNamesFixture";
import { SessionCwdContext } from "../turnChanges/sessionRows";
import { ToolRow } from "./ToolRow";
import { TranscriptDisclosureProvider, resetTranscriptDisclosure } from "./transcriptDisclosure";

const HARNESSES: Record<FixtureHarness, string> = {
  claude: "Claude Code",
  codex: "Codex",
  gemini: "Gemini CLI",
  opencode: "OpenCode",
  pi: "pi",
};

type Look = FixtureHarness | "all";
type Props = { look: Look; mode: "light" | "dark" };

function Rows({ harness }: { harness: FixtureHarness }) {
  return (
    <section className="harness-tool-names__harness">
      <p className="harness-tool-names__name">{HARNESSES[harness]}</p>
      {harnessItems(harness).map((item) => (
        <div key={item.tool!.id} className="acpmux-row">
          <ToolRow item={item} />
        </div>
      ))}
    </section>
  );
}

function HarnessToolNames({ look, mode }: Props) {
  useEffect(() => resetTranscriptDisclosure("gallery-harness-tool-names"), []);
  const harnesses = look === "all" ? (Object.keys(HARNESSES) as FixtureHarness[]) : [look];
  return (
    <TranscriptDisclosureProvider sessionId="gallery-harness-tool-names">
      <SessionCwdContext.Provider value={HARNESS_FIXTURE_CWD}>
        <main className="harness-tool-names acpmux-conversation" data-mode={mode} data-look={look}>
          {harnesses.map((harness) => (
            <Rows key={harness} harness={harness} />
          ))}
        </main>
      </SessionCwdContext.Provider>
    </TranscriptDisclosureProvider>
  );
}

const variant = (look: Look, mode: Props["mode"], note: string): ComponentVariant<Props> => ({
  note: `${note} ${mode === "dark" ? "Dark" : "Light"} theme.`,
  props: { look, mode },
  // Five harnesses' rows stack five times as tall as one's.
  ...(look === "all" ? { height: 880 } : {}),
});

export default componentEntry<Props>({
  id: "agent-pane.harness-tool-names",
  title: "The same tool calls from every harness",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 420, normal: 640, wide: 900 },
  covers: [
    "agent-session/acpmux/toolNames.ts",
    "agent-session/acpmux/toolPaths.ts",
    "agent-session/acpmux/conversation/ToolRow.tsx",
  ],
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./HarnessToolNames.gallery.css")]),
  load: async () => HarnessToolNames,
  keywords: [
    "harness",
    "tool",
    "names",
    "gemini",
    "opencode",
    "pi",
    "codex",
    "claude",
    "read",
    "grep",
    "glob",
    "fetch",
  ],
  variants: {
    all: variant(
      "all",
      "dark",
      "Chosen: all five harnesses, one look; a harness's own readable verb stays (Claude Code's Grep, Codex's Search), any other name takes the canonical verb.",
    ),
    "all-light": variant("all", "light", "All five harnesses, light."),
    claude: variant("claude", "dark", "Claude Code, as acpmux titles it: unchanged."),
    codex: variant("codex", "dark", "Codex's parsed commands and web search: unchanged."),
    gemini: variant("gemini", "dark", "Gemini CLI, whose ACP sends descriptions as titles and no input."),
    opencode: variant("opencode", "dark", "OpenCode, whose titles are its tool names or a bare file name."),
    pi: variant("pi", "dark", "pi, whose titles are its tool names."),
  },
});
