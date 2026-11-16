// l10n-allow-file: gallery fixture text, not shipped UI.
// The example extension examples/extensions/leo-gacha in each card style: its sidebar section
// (left, sidebar width) and its pane (right), drawn by the web scene renderer from the exact op
// batches its renderSection / renderPane exports emitted in the reference fake host
// (scripts/apps/record-scene-traces.ts scripts/apps/specs/leo-gacha.json writes fixtures/leo-gacha-traces.json). One recorded batch is
// applied per second: a pull is shake (1 s), reveal (1 s), rest (1 s). The wiggle, pop, glow,
// shimmer and particles are the renderer's. Chief art resolves from the example's own assets/.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import traces from "./fixtures/leo-gacha-traces.json";
import { SceneRenderer } from "./SceneRenderer";
import { SceneStore, type SceneOp } from "./store";

type Variant = "holo" | "pixel" | "glass";
type Trace = { initial: SceneOp[]; steps: SceneOp[][] };
const TRACES = traces as unknown as Record<string, Trace>;
const PREFIX = "../../../../examples/extensions/leo-gacha/";
const ASSETS = import.meta.glob("../../../../examples/extensions/leo-gacha/assets/**/*.png", {
  eager: true,
  query: "?url",
  import: "default",
}) as Record<string, string>;
const resolveAsset = (bundlePath: string) => ASSETS[PREFIX + bundlePath];

function usePlayback(key: string): SceneStore {
  const [store] = useState(() => {
    const s = new SceneStore();
    s.apply(TRACES[key]!.initial, true);
    return s;
  });
  useEffect(() => {
    const { steps } = TRACES[key]!;
    const at = { step: 0 };
    const timer = window.setInterval(() => {
      if (at.step < steps.length) store.apply(steps[at.step]!);
      at.step += 1;
    }, 1000);
    return () => window.clearInterval(timer);
  }, [key, store]);
  return store;
}

function LeoGacha({ variant = "holo" }: { variant?: Variant }) {
  const section = usePlayback(`${variant}-section`);
  const pane = usePlayback(`${variant}-pane`);
  return (
    <div style={{ display: "flex", gap: 16, padding: 12, alignItems: "flex-start" }}>
      <div
        data-surface="section"
        style={{ width: 280, flex: "none", padding: 8, borderRadius: 10, background: "rgba(127,127,127,0.08)" }}
      >
        <SceneRenderer store={section} dispatch={() => {}} resolveAsset={resolveAsset} />
      </div>
      <div data-surface="pane" style={{ flex: 1, minWidth: 0 }}>
        <SceneRenderer store={pane} dispatch={() => {}} resolveAsset={resolveAsset} />
      </div>
    </div>
  );
}

const ready: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cmux-app-scene-root").length === 2);
};

export default componentEntry<{ variant?: Variant }>({
  id: "apps.leo-gacha",
  title: "Chief gacha (example extension)",
  area: "Apps",
  pane: true,
  height: 860,
  widths: { narrow: 900, normal: 1040 },
  keywords: ["gacha", "chief", "extension", "motion", "particles"],
  covers: ["apps/scene/SceneRenderer.tsx", "apps/scene/SceneParticles.tsx", "apps/scene/motionProps.ts"],
  load: async () => LeoGacha,
  variants: {
    holo: {
      note: "Chosen default: a gradient card in the rarity's colors with a glow; legendary shimmers.",
      props: { variant: "holo" },
      play: ready,
    },
    pixel: {
      note: "A dark card with a thick rarity border; only epic and legendary glow.",
      props: { variant: "pixel" },
      play: ready,
    },
    glass: {
      note: "A see-through card tinted in the rarity's color, with a glow.",
      props: { variant: "glass" },
      play: ready,
    },
  },
});
