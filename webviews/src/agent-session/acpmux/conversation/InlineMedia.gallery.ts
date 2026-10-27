// l10n-allow-file: gallery fixtures (sample replies, paths and images), not shipped UI.
// Screenshots in replies (inlineMedia.ts, chips/ReplyImage.tsx `thumb`): agents show UI with images
// instead of describing it. A before/after pair sits side by side, a labelled pair one per line
// does too, an image path in a sentence stays its chip with the thumbnail under the paragraph, a
// PR's media on raw.githubusercontent.com loads at once, and an image from any other site waits for Load image in
// the same frame.
import { agentPaneEntry, type ChipHostFixture } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { LOGIN_TESTS_MP4 } from "../../../gallery/fixtures/toolImages";
import { sampleChart, sampleDiagram, sampleGradient } from "../mockFixture";

const ROOT = "/Users/you/src/atlas-web";
const BEFORE = `${ROOT}/shots/tabs-before.png`;
const AFTER = `${ROOT}/shots/tabs-after.png`;
const SIDEBAR = `${ROOT}/shots/sidebar.png`;
const PR_MEDIA = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/23650/tabs-light.png";
const PR_BEFORE = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/24546/tray-before-dark.png";
const PR_AFTER = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/24546/tray-after-dark.png";
const WEB_IMAGE = "https://images.example.test/gallery/chart.png";
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
  images: {
    [BEFORE]: svg(sampleChart()),
    [AFTER]: svg(sampleGradient()),
    [SIDEBAR]: svg(sampleDiagram()),
    [PR_MEDIA]: svg(sampleGradient()),
    [PR_BEFORE]: svg(sampleChart()),
    [PR_AFTER]: svg(sampleGradient()),
    [WEB_IMAGE]: svg(sampleDiagram()),
  },
  media: { [VIDEO]: MP4, [REEL]: MP4 },
  // As the host answers it: raw.githubusercontent.com loads without a click (AgentPaneSafeFetch.clickFreeImageHosts).
  policy: {
    outsideRoots: "confirm",
    remoteImages: "click",
    clickFreeImageHosts: ["raw.githubusercontent.com"],
  },
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
      note: "A PR's media address on raw.githubusercontent.com loads at once under images.remote = click (the click-free site).",
      chipHost: HOST,
      snapshot: reply("Where are the PR screenshots?", `Light mode:\n\n![Tabs, light](${PR_MEDIA})`),
    },
    "pr-media-pair": {
      note: "A before/after pair from a PR's media on raw.githubusercontent.com: both draw inline side by side, no Load image.",
      chipHost: HOST,
      snapshot: reply(
        "Is the tray glass now?",
        `A Codex reviewer approved it and the compile passed.\n\n![](${PR_BEFORE}) ![](${PR_AFTER})\n\nAbove is before and after in dark.`,
      ),
    },
    "web-image": {
      note: "An image from any other site still waits for Load image in the glass frame (images.remote = click).",
      chipHost: HOST,
      snapshot: reply("Show the chart", `The chart:\n\n![Chart](${WEB_IMAGE})`),
    },
    "video-thumbnail": {
      note: "Before hover intent: a video in a reply shows its poster frame, a glass play button and its length.",
      chipHost: HOST,
      snapshot: reply("Record the login tests", `The recording of the six login tests:\n\n![Login tests](${VIDEO})`),
    },
    "video-hover-intent": {
      note: "After hover intent: the muted preview starts after a deliberate 250 ms rest and the poster eases back; motion-off users stay on the poster.",
      chipHost: HOST,
      snapshot: reply("Record the login tests", `The recording of the six login tests:\n\n![Login tests](${VIDEO})`),
      play: async (ctx) => {
        await ctx.hover({ selector: ".cv-media__poster" });
        await ctx.waitFor(() => ctx.document.querySelector('.cv-media__frame[data-previewing="true"]'));
      },
    },
    "web-video-thumbnail": {
      note: "A nightly reel link alone on its line with images.remote = always: the host's checked copy draws as the same thumbnail.",
      chipHost: { ...HOST, policy: { outsideRoots: "confirm", remoteImages: "always" } },
      snapshot: reply("What changed in the last nightly?", `The nightly reel:\n\n${REEL}`),
    },
  },
});
