// l10n-allow-file: gallery fixtures, not shipped UI.
// A long chat whose open page holds only its last two turns: the turn before them ran a build whose log
// took most of the 128 KB page (direct.ts OPEN_PAGE_BYTES). Leo, 2026-11-12 (ask-62e23da040): "can you
// please fix the rendering bug on my agent chat area"; his NIGHTLY drew nothing in the top ~40% of the
// chat above "Received 3 messages". The rows do not reach the view's top, so the transcript asks for
// the next older page with `fill` and the client lands the first page that starts an older turn, one
// daemon round trip, instead of four read one after another (test/agent-pane-blank-top-browser.test.ts).
import { agentPaneEntry } from "../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "./model";

/// The open page: the build turn and the turn after it, newest last.
const openPage = (): AcpmuxRow[] => [
  { ...user("Run the whole suite.", 12), id: "short-user-build" },
  activity([tool("Run bun test", "execute", "completed")], 11, { id: "short-activity-build" }),
  assistant("The suite passed.", 10, { id: "short-assistant-build" }),
  summary(10, { id: "short-summary-build", status: "completed", toolCount: 1 }),
  { ...user("Three notes came in from the other lanes; read them and say what changes.", 4), id: "short-user-notes" },
  assistant("Noted, all three. Nothing changes here: the retry loop is done and the nightly is green.", 3, {
    id: "short-assistant-notes",
  }),
  summary(3, { id: "short-summary-notes", status: "completed" }),
];

/// The first older page, landed above the open page: the turns before the build.
const olderPage = (): AcpmuxRow[] =>
  Array.from({ length: 6 }, (_, index) => {
    const n = 394 + index;
    const minutes = 60 - index * 8;
    return [
      { ...user(`Turn ${n}: why does step ${n} let values past the guard?`, minutes), id: `short-user-${n}` },
      activity([tool(`Edit step${n}.ts`, "edit", "completed")], minutes - 1, { id: `short-activity-${n}` }),
      assistant(`Done with turn ${n}: the guard compares against the cap before the value is clamped.`, minutes - 2, {
        id: `short-assistant-${n}`,
      }),
      summary(minutes - 2, { id: `short-summary-${n}`, status: "completed", toolCount: 1 }),
    ];
  }).flat();

const longChat = (rows: AcpmuxRow[]) => chat(rows, { title: "Retry loop", canLoadOlder: true });

export default agentPaneEntry({
  id: "agent-pane.transcript-short-open",
  title: "Transcript: a long chat whose open page is short",
  area: "Agent pane",
  height: 620,
  covers: ["agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript", "agent-session/acpmux/direct.ts"],
  variants: {
    "open-page": {
      note: "The first frame: the open page's two turns at the bottom and older history still left to load. With a fill read this lasts one older page's round trip; before, four pages one after another.",
      snapshot: longChat(openPage()),
    },
    "first-older-page": {
      note: "One older page landed with the fill read: rows reach the view's top, and the next pages are asked six viewports ahead as before.",
      snapshot: longChat([...olderPage(), ...openPage()]),
    },
    narrow: {
      note: "The same after the first older page, in a short pane: the page's rows fill it from the top.",
      height: 380,
      snapshot: longChat([...olderPage(), ...openPage()]),
    },
  },
});
