// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// Images in a reply (Markdown.tsx draws a data URL image inline; a click opens ImageViewer.tsx over
// the pane, with arrows through every image of the chat). The opened viewer needs a click, so its
// states wait for play steps; these show what a reader clicks.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { sampleChart, sampleDiagram, sampleGradient } from "../mockFixture";

const image = (alt: string, svg: string) => `![${alt}](data:image/svg+xml;base64,${btoa(svg)})`;

export default agentPaneEntry({
  id: "agent-pane.image-viewer",
  title: "Image viewer",
  area: "Agent pane",
  covers: ["agent-session/acpmux/conversation/ImageViewer.tsx"],
  variants: {
    "reply-images": {
      note: "A reply with three images; each opens the viewer.",
      snapshot: chat(
        [
          user("Make sample images for the docs", 8),
          assistant(
            [
              "Made three sample images: a chart, a gradient and a diagram.",
              image("Weekly builds", sampleChart()),
              image("Dusk gradient", sampleGradient()),
              image("Request flow", sampleDiagram()),
            ].join("\n\n"),
            7,
          ),
          summary(7, { status: "completed" }),
        ],
        { title: "Make sample images for the docs" },
      ),
    },
    "across-turns": {
      note: "Images in two replies: the viewer's arrows go through both.",
      snapshot: chat(
        [
          user("Chart this week's builds", 12),
          assistant(`Builds per day:\n\n${image("Weekly builds", sampleChart())}`, 11),
          summary(11, { status: "completed" }),
          user("Now draw the request flow", 6),
          assistant(`The request path:\n\n${image("Request flow", sampleDiagram())}`, 5),
          summary(5, { status: "completed" }),
        ],
        { title: "Build charts" },
      ),
    },
  },
});
