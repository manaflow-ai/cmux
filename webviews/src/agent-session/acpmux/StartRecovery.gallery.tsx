// l10n-allow-file: gallery fixtures and developer descriptions.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { startRecoveryLook } from "./startRecovery.experiment";
import type { StartRecoveryScene } from "./StartRecovery.galleryScene";
import type { ComponentProps } from "react";

const start: Play = async (ctx) => {
  if (!ctx.document.querySelector('[role="dialog"]')) {
    await ctx.click({ role: "button", name: "Start" });
  }
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"]'));
};

export default componentEntry<ComponentProps<typeof StartRecoveryScene>>({
  id: "agent-pane.start-recovery",
  title: "Start recovery (Labs)",
  area: "Agent pane",
  experimental: true,
  covers: ["agent-session/acpmux/StartRecovery.tsx", "agent-session/acpmux/startRecoveryPreview.ts"],
  load: () => import("./StartRecovery.galleryScene").then((m) => m.StartRecoveryScene),
  styles: () => Promise.all([import("./styles.css"), import("../../ui/ui.css"), import("../../ui/popupSurface.css")]),
  widths: { narrow: 320, normal: 560, wide: 820 },
  height: 360,
  variants: {
    newtab: { props: {}, play: start },
    chat: { props: { surface: "chat" }, play: start },
    off: {
      props: { enabled: false },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Start" });
      },
    },
    keyboard: {
      props: {},
      play: async (ctx) => {
        await start(ctx);
        await ctx.press("Escape");
        await ctx.waitFor(() => !ctx.document.querySelector('[role="dialog"]'));
        await ctx.waitFor(() => ctx.document.activeElement?.textContent === "Start");
      },
    },
    "action-failure": {
      note: "Presentation fixture: the setup owner retains a refusal; real Agents setup owns its own failures.",
      props: { setupFails: true },
      play: async (ctx) => {
        await start(ctx);
        await ctx.click({ selector: '[role="dialog"] button[data-variant="solid"]' });
        await ctx.waitFor(() => !ctx.document.querySelector('[role="dialog"]'));
      },
    },
    "stale-selection": {
      props: {},
      play: async (ctx) => {
        await start(ctx);
        await ctx.press("Escape");
        await ctx.waitFor(() => !ctx.document.querySelector('[role="dialog"]'));
        await ctx.click({ role: "button", name: "Change selection" });
        await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"]')?.textContent?.includes("Codex"));
      },
    },
  },
  experiment: { definition: startRecoveryLook, script: [{ name: "Open recovery", run: start }] },
});
