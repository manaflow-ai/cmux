// l10n-allow-file: gallery fixture text, not shipped UI.
// The finished components (RFD 0009 slice 4): Stat and Chart, which the host draws from data, and
// every finished component's variants (standard, prominent, subtle) and states (loading, error,
// empty). fixtures/components-scenes.json holds the ops cmux-app-host/js/test/components/src/main.ts
// emits in the fake host; cmux-app-host/js/test/components.test.ts records them
// (CMUX_RECORD_COMPONENTS=1), and the Rust design check reads them back with no findings.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import scenes from "./fixtures/components-scenes.json";
import { SceneRenderer } from "./SceneRenderer";
import { SceneStore, type SceneOp } from "./store";

type Scene = "stats" | "charts" | "variants" | "states";
type Props = { scene?: Scene };

const recorded = scenes as unknown as Record<Scene, SceneOp[]>;

function Components({ scene = "stats" }: Props) {
  const [store] = useState(() => {
    const s = new SceneStore();
    s.apply(recorded[scene], true);
    return s;
  });
  return <SceneRenderer store={store} dispatch={() => {}} />;
}

export default componentEntry<Props>({
  id: "apps.components",
  title: "Finished components: Stat, Chart, variants and states",
  area: "Apps",
  pane: true,
  height: 520,
  widths: { narrow: 360, normal: 560 },
  keywords: ["Stat", "Chart", "sparkline", "variant", "prominent", "subtle", "loading", "error", "empty", "state"],
  covers: ["apps/scene/SceneRenderer.tsx", "apps/scene/sceneComponents.tsx"],
  load: async () => Components,
  variants: {
    stats: {
      note: "Stat: a 34 pt value, a caption and a delta. Requests up is good (success); latency up is bad (danger, goodTrend down); uptime is flat. Below, one Stat in each variant.",
      props: { scene: "stats" },
    },
    charts: {
      note: "Chart from a number series: a line, bars, bars below zero in warning, and a line in each variant (prominent fills under the line, subtle is secondary).",
      props: { scene: "charts" },
    },
    variants: {
      note: "Badge, Button, Row and ProgressView, each standard, prominent and subtle.",
      props: { scene: "variants" },
    },
    states: {
      note: "Loading, error and empty drawn in place of a Stat and a Chart, a Row loading with a message, a Button in error, and a Gauge empty.",
      props: { scene: "states" },
    },
  },
});
