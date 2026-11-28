// l10n-allow-file: SDK scene verification fixture, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { TooltipProvider } from "../../ui/Tooltip";
import { SceneMount } from "./panels";
import type { MountedPanel } from "./panelsClient";
import { SceneStore } from "./store";
import { sdkKitHover } from "./fixtures/sdkKitHover";

function SceneKit() {
  const [mounted] = useState<MountedPanel>(() => {
    const store = new SceneStore();
    store.apply(sdkKitHover);
    return {
      panel: { app: "local/sdk-hover-proof", section: "gallery", title: "SDK kit" },
      store,
      dispatch: () => undefined,
      reload: () => store.apply(sdkKitHover, true),
      layout: () => undefined,
      resolveAsset: () => undefined,
    };
  });
  return (
    <TooltipProvider>
      <div style={{ padding: 32, minHeight: 300 }}>
        <div style={{ width: 180 }}>
          <SceneMount mounted={mounted} />
        </div>
        <p data-testid="sdk-hover-away" style={{ marginTop: 160 }}>
          Outside the scene
        </p>
      </div>
    </TooltipProvider>
  );
}

const tooltip: Play = async (ctx) => {
  await ctx.hover({ selector: '[data-app-node="sdk-pill"]' });
  await ctx.waitFor(() => {
    const tip = ctx.document.querySelector('[role="tooltip"]');
    return tip?.textContent === "Open the latest run";
  });
};
const card: Play = async (ctx) => {
  await ctx.hover({ selector: '[data-app-node="sdk-trigger"]' });
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"] [data-app-node="sdk-detail"]'));
};
const crossed: Play = async (ctx) => {
  await card(ctx);
  await ctx.hover({ selector: '[role="dialog"] [data-app-node="sdk-action"]' });
  // Moving into the portal must keep the actual SDK content usable.
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"] [data-app-node="sdk-action"]'));
};
const left: Play = async (ctx) => {
  await crossed(ctx);
  await ctx.hover({ testId: "sdk-hover-away" });
  await ctx.waitFor(() => !ctx.document.querySelector('[role="dialog"]'));
};

export default componentEntry({
  id: "apps.scene-kit-hover",
  title: "SDK Pill, Tooltip and Card",
  area: "Apps",
  pane: true,
  height: 400,
  widths: { narrow: 420, normal: 560 },
  covers: ["apps/scene/SceneRenderer.tsx", "ui/Tooltip.tsx", "agent-session/acpmux/chips/useHoverCard.ts"],
  load: async () => SceneKit,
  variants: {
    closed: { note: "The SDK Pill and Card trigger, before any hover.", props: {} },
    tooltip: { note: "The SDK Tooltip opens over its success Pill.", props: {}, play: tooltip },
    card: { note: "The SDK Card opens after the real shared dwell.", props: {}, play: card },
    crossed: {
      note: "The pointer crosses into the Card's portalled action.",
      props: {},
      play: crossed,
    },
    left: {
      note: "Leaving the Card closes its portal after the shared grace.",
      props: {},
      play: left,
    },
  },
});
