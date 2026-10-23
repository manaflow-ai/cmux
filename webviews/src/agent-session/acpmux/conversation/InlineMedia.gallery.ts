// l10n-allow-file: gallery fixtures (sample replies, paths and images), not shipped UI.
// Screenshots in replies (inlineMedia.ts, chips/ReplyImage.tsx `thumb`): agents show UI with images
// instead of describing it. A before/after pair sits side by side, a labelled pair one per line
// does too, an image path in a sentence stays its chip with the thumbnail under the paragraph, and a
// PR's media waits for Load image in the same frame.
import { agentPaneEntry, type ChipHostFixture } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { LOGIN_TESTS_MP4 } from "../../../gallery/fixtures/toolImages";
import { sampleChart, sampleDiagram, sampleGradient } from "../mockFixture";

const ROOT = "/Users/you/src/atlas-web";
const BEFORE = `${ROOT}/shots/tabs-before.png`;
const AFTER = `${ROOT}/shots/tabs-after.png`;
const SIDEBAR = `${ROOT}/shots/sidebar.png`;
const PR_MEDIA = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/23650/tabs-light.png";
const VIDEO = `${ROOT}/out/login-tests.mp4`;
const REEL = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/nightly-next/3969193/reel.mp4";
const MP4 = `data:video/mp4;base64,${LOGIN_TESTS_MP4}`;

const svg = (markup: string) => `data:image/svg+xml;base64,${btoa(markup)}`;

const HOST: ChipHostFixture = {
  paths: {
    [BEFORE]: { place: "root", folder: false },
    [AFTER]: { place: "root", folder: false },
    [SIDEBAR]: { place: "root", folder: false },
    [VIDEO]: { place: "root", folder: false },
  },
  images: { [BEFORE]: svg(sampleChart()), [AFTER]: svg(sampleGradient()), [SIDEBAR]: svg(sampleDiagram()) },
  media: { [VIDEO]: MP4, [REEL]: MP4 },
  policy: { outsideRoots: "confirm", remoteImages: "click" },
};

const reply = (prompt: string, text: string) =>
  chat([user(prompt, 3), assistant(text, 2.9), summary(2.9)], { title: prompt });

export default agentPaneEntry({
  id: "agent-pane.inline-media",
  title: "Screenshots in replies",
  area: "Agent pane",
  height: 560,
  covers: [
    "agent-session/acpmux/conversation/Markdown.tsx",
    "agent-session/acpmux/chips/ReplyImage.tsx#OpenableImage",
    "agent-session/acpmux/chips/ReplyMedia.tsx#VideoThumbnail",
    "agent-session/acpmux/conversation/icons.tsx#OpenTab",
  ],
  variants: {
    "before-after": {
      note: "Two Markdown images on one line: side by side, captioned by their alt text; each opens the viewer.",
      chipHost: HOST,
      snapshot: reply(
        "Make the tab group line thinner",
        `The group line is thinner now, with a small gap under the header.\n\n![Before](${BEFORE}) ![After](${AFTER})`,
      ),
    },
    "labelled-lines": {
      note: "Bare paths with Before:/After: labels on their own lines: the same side-by-side pair.",
      chipHost: HOST,
      snapshot: reply("Show me the change", `Here it is:\n\n**Before:** ${BEFORE}\n**After:** ${AFTER}`),
    },
    "path-in-sentence": {
      note: "An image path in a sentence stays a chip; its thumbnail draws under the paragraph.",
      chipHost: HOST,
      snapshot: reply(
        "Screenshot the sidebar",
        `Saved the sidebar screenshot to ${SIDEBAR}; the hover row now uses the theme accent.`,
      ),
    },
    "pr-media": {
      note: "A PR's media address: the glass frame holds Load image (agentPane.images.remote = click).",
      chipHost: HOST,
      snapshot: reply("Where are the PR screenshots?", `Light mode:\n\n![Tabs, light](${PR_MEDIA})`),
    },
    "video-thumbnail": {
      note: "A video in a reply: its poster frame, a glass play button and its length; a click plays it, Open in tab opens it beside the chat.",
      chipHost: HOST,
      snapshot: reply("Record the login tests", `The recording of the six login tests:\n\n![Login tests](${VIDEO})`),
    },
    "web-video-thumbnail": {
      note: "A nightly reel link alone on its line with images.remote = always: the host's checked copy draws as the same thumbnail.",
      chipHost: { ...HOST, policy: { outsideRoots: "confirm", remoteImages: "always" } },
      snapshot: reply("What changed in the last nightly?", `The nightly reel:\n\n${REEL}`),
    },
  },
});
