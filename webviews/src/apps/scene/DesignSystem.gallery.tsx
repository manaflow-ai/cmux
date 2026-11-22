// l10n-allow-file: gallery fixture text, not shipped UI.
// A design system's page (cmux-extension-sdk's DesignSystemView, design.ts): the example extension
// examples/extensions/design-system's pane, showing cmux's own system and the example's
// (cmux-design.json: numeral and heading overridden, a code role added, a 7-step scale, brand and
// muted named). fixtures/design-system-scenes.json holds the ops the pane's render emits in the fake
// host; cmux-app-host/js/test/design.test.ts records them (CMUX_RECORD_DESIGN_SYSTEM=1).
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import scenes from "./fixtures/design-system-scenes.json";
import { SceneRenderer } from "./SceneRenderer";
import { SceneStore, type SceneOp } from "./store";

type State = "cmux" | "custom";
type Props = { state?: State };

const recorded = scenes as unknown as Record<State, SceneOp[]>;

function DesignSystem({ state = "cmux" }: Props) {
  const [store] = useState(() => {
    const s = new SceneStore();
    s.apply(recorded[state], true);
    return s;
  });
  return <SceneRenderer store={store} dispatch={() => {}} />;
}

export default componentEntry<Props>({
  id: "apps.design-system",
  title: "Design system page (example extension)",
  area: "Apps",
  pane: true,
  height: 2000,
  widths: { narrow: 420, normal: 560 },
  keywords: [
    "design system",
    "cmux.design/1",
    "cmux-design.json",
    "tokens",
    "type roles",
    "spacing",
    "DesignSystemView",
  ],
  covers: ["apps/scene/SceneRenderer.tsx"],
  load: async () => DesignSystem,
  variants: {
    cmux: {
      note: "cmux's own system: its seven type roles as specimens, the 11-step spacing scale, the color roles, the widget components drawn with it, and 4 type roles and 2 accents a view.",
      props: { state: "cmux" },
    },
    custom: {
      note: "The example's system on top of cmux's: numeral 40 bold and heading 22 bold marked overrides, code (12 pt monospaced) marked added, a 7-step scale, brand and muted as aliases of accent and secondary.",
      props: { state: "custom" },
    },
  },
});
