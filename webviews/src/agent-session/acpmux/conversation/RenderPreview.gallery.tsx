// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { RenderCall } from "./renderCall";

type Props = { call: RenderCall; streaming: boolean };

export default componentEntry<Props>({
  id: "agent-pane.render-preview",
  title: "Writing a page",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/conversation/RenderPreview.tsx#RenderPreview"],
  load: async () => (await import("./RenderPreview")).RenderPreview,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css"), import("./renderPreview.css")]),
  widths: { narrow: 320, normal: 720, wide: 960 },
  variants: {
    html: {
      play: async (ctx) => {
        ctx.document.documentElement.setAttribute("data-lab-live-render", "on");
      },
      props: {
        call: {
          html: "<title>Build report</title><h2>Build times</h2><p>The first lane finished.</p><table><tr><th>Lane</th><th>Time</th></tr><tr><td>Portable checks</td><td>4.2 s</td></tr><tr><td>App",
        },
        streaming: true,
      },
    },
    component: {
      play: async (ctx) => {
        ctx.document.documentElement.setAttribute("data-lab-live-render", "on");
      },
      props: {
        call: {
          html: "<!-- cmux-react -->\n// title: Build report\nfunction App() {\n  return <section>\n    <h2>Build times</h2>\n    <p>The first lane finished.</p>",
        },
        streaming: true,
      },
    },
  },
});
