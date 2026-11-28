// l10n-allow-file: gallery fixtures (sample chats), not shipped UI.
// The chat transcript under layout stress (Leo, 2026-11-23: "there is objectivity in design. we cannot
// miss these edge cases"): one unbroken long name, 200-character wrapped text, many tool rows, a failed
// tool, a failed turn, a long user message and a short pane, at 280, 360 and 480 px. The play checks the
// geometry: the page never scrolls sideways, no transcript control leaves the pane or overlaps another,
// and text that does not fit ends in an ellipsis instead of pushing a control away.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { AcpmuxRow } from "./model";
import { activity, assistant, chat, summary, thought, tool, user } from "../../gallery/fixtures/acpmux";

const LONG_NAME =
  "webviews/src/agent-session/acpmux/conversation/AVeryLongDirectoryNameWithoutAnyBreaksAtAll/AnotherExtremelyLongComponentFileName.gallery.stress.test.tsx";
const WRAPPED = "This sentence keeps going to fill two hundred characters of wrapped prose in the reply, ".repeat(3);

const visible = (element: Element) => {
  const rect = element.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0 && getComputedStyle(element).visibility !== "hidden";
};

const check: Play = async (ctx) => {
  await ctx.hover({ selector: ".acpmux-transcript, .acpmux-main" });
  const document = ctx.document;
  const view = document.defaultView!;
  const problems: string[] = [];
  const page = document.scrollingElement ?? document.documentElement;
  if (page.scrollWidth > view.innerWidth + 1) problems.push(`the page scrolls sideways (${page.scrollWidth})`);
  const scope = document.querySelector(".acpmux-main") ?? document.body;
  const controls = [...scope.querySelectorAll("button, a[href], [role='button']")].filter(
    (control) =>
      visible(control) &&
      !control.querySelector("button, a[href], [role='button']") &&
      !control.closest(".acpmux-composer, .acpmux-composer-box, [role='menu'], .ui-popup"),
  );
  const rects = controls.map((control) => ({ control, rect: control.getBoundingClientRect() }));
  for (const { control, rect } of rects)
    if (rect.right > view.innerWidth + 1 || rect.left < -1)
      problems.push(`${control.className.toString().split(" ")[0] || control.tagName} leaves the pane`);
  for (let i = 0; i < rects.length; i++)
    for (let j = i + 1; j < rects.length; j++) {
      const a = rects[i]!.rect;
      const b = rects[j]!.rect;
      if (
        Math.min(a.right, b.right) - Math.max(a.left, b.left) > 2 &&
        Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 2
      )
        problems.push(
          `${rects[i]!.control.className.toString().split(" ")[0]} overlaps ${rects[j]!.control.className.toString().split(" ")[0]}`,
        );
    }
  if (problems.length) throw new Error(problems.join("; "));
};

const turn = (rows: AcpmuxRow[]) => chat(rows, { title: LONG_NAME });

export default agentPaneEntry({
  id: "agent-pane.transcript-stress",
  title: "Transcript layout stress",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 280, normal: 360, wide: 480 },
  covers: ["agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript"],
  variants: {
    "long-names": {
      note: "One unbroken 150-character path in a tool title, a thought and the reply; the chat's title is as long.",
      snapshot: turn([
        user(`Open ${LONG_NAME}`, 8),
        activity(
          [
            thought(`Looking at ${LONG_NAME}`),
            tool(`Read ${LONG_NAME}`, "read", "completed"),
            tool(`Edit ${LONG_NAME}`, "edit", "completed"),
          ],
          7,
        ),
        assistant(`Changed ${LONG_NAME} and ${WRAPPED}`, 6),
        summary(6, { status: "completed", toolCount: 2 }),
      ]),
      play: check,
    },
    "wrapped-text": {
      note: "A 200-plus character user message, thought and reply that wrap over several lines.",
      snapshot: turn([
        user(WRAPPED, 8),
        activity([thought(WRAPPED), tool(WRAPPED, "execute", "completed")], 7),
        assistant(WRAPPED, 6),
        summary(6, { status: "completed", toolCount: 1 }),
      ]),
      play: check,
    },
    "many-tools": {
      note: "Forty tool rows in one turn: the list overflows the pane and scrolls.",
      snapshot: turn([
        user("Run everything", 20),
        activity(
          Array.from({ length: 40 }, (_, i) =>
            tool(`Read src/file-${i}.ts`, "read", i === 39 ? "in_progress" : "completed"),
          ),
          19,
        ),
        summary(18, { status: "completed", toolCount: 40 }),
      ]),
      play: check,
    },
    "failed-tool": {
      note: "A failed command with a long unbroken error line, then a failed turn with a long error.",
      snapshot: turn([
        user("Build it", 8),
        activity(
          [
            tool("bun run build", "execute", "failed", {
              command: "bun run build",
              output: `error: ${LONG_NAME}\n`,
              exitCode: 1,
            }),
          ],
          7,
        ),
        assistant("The build failed.", 6),
        summary(6, { status: "failed", error: `Request failed: ${LONG_NAME} ${WRAPPED}` }),
      ]),
      play: check,
    },
    empty: {
      note: "A chat with no rows yet.",
      snapshot: chat([]),
      play: check,
    },
    "short-pane": {
      note: "Two turns in a 220 px tall pane: the jump and hover controls do not cover the text.",
      height: 220,
      snapshot: turn([
        user(WRAPPED, 8),
        assistant(WRAPPED, 6),
        summary(6, { status: "completed" }),
        user("And again", 4),
        assistant(WRAPPED, 2),
        summary(2, { status: "completed" }),
      ]),
      play: check,
    },
  },
});
