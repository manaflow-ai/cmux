// l10n-allow-file: synthetic gallery labels, not shipped UI.
import { componentEntry } from "../../../gallery/format";

export default componentEntry({
  id: "new-tab.dot-focus",
  title: "New Tab dot focus",
  area: "New Tab",
  height: 200,
  widths: { narrow: 340, normal: 540, wide: 760 },
  covers: ["agent-session/acpmux/newtab/StyleSwitch.tsx#DotSwitch"],
  load: async () => (await import("./DotSwitch.fixture")).default,
  styles: () => Promise.all([import("./screen.css"), import("./DotSwitch.gallery.css")]),
  variants: { initial: { props: {} } },
});
