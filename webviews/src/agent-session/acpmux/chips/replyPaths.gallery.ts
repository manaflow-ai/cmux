// l10n-allow-file: gallery fixtures (sample replies and paths), not shipped UI.
// Paths in replies (chips/paths.ts, decisions D4 and D5): the fleet status reply from Lawrence's
// 2026-10-06 screenshot, whose files are in /tmp outside the session's folders, and one reply with
// every form a path is written in (prose, code spans, links, file URLs, folders, line suffixes).
import { agentPaneEntry, type ChipHostFixture } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const FLEET_REPLY = [
  "Rendered the build fleet status: `/tmp/fleetviz/out/fleet.png` and `/tmp/fleetviz/out/fleet.html`.",
  "",
  "![Build fleet status](/tmp/fleetviz/out/fleet.png)",
].join("\n");

const FLEET_HOST: ChipHostFixture = {
  paths: {
    "/tmp/fleetviz/out/fleet.png": { place: "outside", folder: false },
    "/tmp/fleetviz/out/fleet.html": { place: "outside", folder: false },
  },
  policy: { outsideRoots: "confirm", remoteImages: "click" },
};

const ROOT = "/Users/you/src/atlas-web";
const PATH_FORMS = [
  "## Every way a path is written",
  "",
  `- Prose: ${ROOT}/src/net/retry.ts:42, the folder ${ROOT}/src/net/ and ./docs/networking.md.`,
  `- Code spans: \`${ROOT}/src/net/client.ts\`, \`~/notes/todo.md\`, \`./docs/\` and \`/Users/you/Library/Application Support/cmux/settings.json\`.`,
  `- Links: [the retry module](${ROOT}/src/net/retry.ts), [report](file:///tmp/atlas/report.html) and [notes](./docs/networking.md).`,
  "- A file URL in prose: file:///tmp/atlas/report.html.",
  "- Outside the project: `/tmp/atlas/build.log` and /tmp/atlas/report.html.",
  "- Missing: `" + ROOT + "/src/gone.ts`. Deny-listed: `~/.ssh/id_ed25519` and `" + ROOT + "/.env.local`.",
  "- Code that is not a path stays code: `ls /tmp`, `rm -rf /tmp/x/*.log`, `README.md` and `/usr`.",
].join("\n");

const FORMS_HOST: ChipHostFixture = {
  paths: {
    [`${ROOT}/src/net/retry.ts`]: { place: "root", folder: false },
    [`${ROOT}/src/net/`]: { place: "root", folder: true },
    "./docs/networking.md": { place: "root", folder: false },
    [`${ROOT}/src/net/client.ts`]: { place: "root", folder: false },
    "~/notes/todo.md": { place: "outside", folder: false },
    "./docs/": { place: "root", folder: true },
    "/Users/you/Library/Application Support/cmux/settings.json": { place: "outside", folder: false },
    "/tmp/atlas/report.html": { place: "outside", folder: false },
    "/tmp/atlas/build.log": { place: "outside", folder: false },
    [`${ROOT}/src/gone.ts`]: { place: "missing", folder: false },
  },
  policy: { outsideRoots: "confirm", remoteImages: "click" },
};

export default agentPaneEntry({
  id: "agent-pane.reply-paths",
  title: "Paths in replies",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/chips/LinkChips.tsx#PathChip", "agent-session/acpmux/chips/ReplyImage.tsx#ReplyImage"],
  variants: {
    "fleet-reply": {
      note: "The fleet reply: two /tmp paths in code are chips with a lock; the /tmp image is outside the folders.",
      chipHost: FLEET_HOST,
      snapshot: chat([user("Render the build fleet status", 3), assistant(FLEET_REPLY, 2.9), summary(2.9)]),
    },
    "path-forms": {
      note: "One detector for prose, code spans and links: files, folders, ./ paths, file URLs, line suffixes.",
      chipHost: FORMS_HOST,
      snapshot: chat([user("Where are the files?", 3), assistant(PATH_FORMS, 2.9), summary(2.9)]),
    },
  },
});
