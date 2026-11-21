// l10n-allow-file: gallery fixtures (a made-up run), not shipped UI.
// Share poster…: a finished run as a shareable image (the "look what my agent just did" post).
// Three designs, each light and dark, then the dialog that previews it before anything leaves the
// Mac. Shipped: glow.
import { useMemo } from "react";
import { componentEntry } from "../../../../gallery/format";
import type { PosterDesign, PosterTheme } from "./Poster";
import type { PosterData } from "./posterModel";

type Props = {
  design: PosterDesign;
  theme: PosterTheme;
  run: "full" | "shots" | "small" | "linked";
  dialog?: boolean;
};

export default componentEntry<Props>({
  id: "agent-pane.share-poster",
  title: "Agent pane: share a run as a poster",
  area: "Agent pane",
  keywords: ["share", "poster", "image", "screenshot", "png", "export", "card", "social"],
  covers: [
    "agent-session/acpmux/share/poster/Poster.tsx",
    "agent-session/acpmux/share/poster/PosterDialog.tsx",
    "agent-session/acpmux/share/poster/posterModel.ts",
  ],
  height: 820,
  load: async () => {
    const [{ Poster }, { PosterDialogBody, posterLabels }, fixtures, { useT }] = await Promise.all([
      import("./Poster"),
      import("./PosterDialog"),
      import("./posterFixtures"),
      import("../../i18n"),
    ]);
    const runs = (theme: PosterTheme): Record<Props["run"], PosterData> => ({
      full: fixtures.posterRun,
      shots: fixtures.posterRunShots(theme === "dark"),
      small: fixtures.posterRunSmall,
      linked: fixtures.posterRunLinked,
    });
    return function GalleryPoster({ design, theme, run, dialog }: Props) {
      const t = useT();
      const labels = useMemo(() => posterLabels(t), [t]);
      const data = runs(theme)[run];
      const none = () => {};
      if (dialog)
        return (
          <div className="ui-glass ui-glass-floats ui-dialog poster-dialog-popup poster-gallery__dialog">
            <PosterDialogBody
              data={data}
              design={design}
              theme={theme}
              includeLink={run === "linked"}
              busy={false}
              status={null}
              onIncludeLink={none}
              onCopy={none}
              onSave={none}
              onDone={none}
            />
          </div>
        );
      return <Poster data={data} design={design} theme={theme} labels={labels} className="poster-gallery__image" />;
    };
  },
  styles: () => import("./Poster.gallery.css"),
  variants: {
    "glow-dark": {
      note: "Shipped: glow, dark. The prompt large, the run (harness, model, time) on the right, files changed with + and −, four hunks in a 2 by 2 grid, Made with cmux. Soft blue and violet light on a deep ground: reads as a product shot in a feed.",
      props: { design: "glow", theme: "dark", run: "full" },
    },
    "glow-light": {
      note: "Shipped: glow, light. The same layout on a pale ground; the dialog picks the pane's own light or dark.",
      props: { design: "glow", theme: "light", run: "full" },
    },
    "glow-shots-dark": {
      note: "Shipped: a turn that changed UI. Two hunks on the left, the prompt's picture (Before) and the last picture a tool returned (After) on the right.",
      props: { design: "glow", theme: "dark", run: "shots" },
    },
    "glow-shots-light": {
      note: "Shipped: the same, light.",
      props: { design: "glow", theme: "light", run: "shots" },
    },
    "glow-small": {
      note: "Shipped: a one-file fix. The lone hunk takes the whole row; nothing else moves.",
      props: { design: "glow", theme: "dark", run: "small" },
    },
    "glow-linked": {
      note: "Shipped: Include share link on. The chat's viewer link prints at the footer's right.",
      props: { design: "glow", theme: "dark", run: "linked" },
    },
    "terminal-dark": {
      note: "Compared, not shipped: terminal. A window with traffic lights, the prompt after ❯ in monospace. Honest, but it reads as any terminal screenshot; nothing says cmux until the footer.",
      props: { design: "terminal", theme: "dark", run: "full" },
    },
    "terminal-light": {
      note: "Compared, not shipped: terminal, light.",
      props: { design: "terminal", theme: "light", run: "full" },
    },
    "editorial-dark": {
      note: "Compared, not shipped: editorial. Larger type, a flat ground and an accent rule. Calm, but the diff loses its weight against the prompt and the counts.",
      props: { design: "editorial", theme: "dark", run: "full" },
    },
    "editorial-light": {
      note: "Compared, not shipped: editorial, light (paper).",
      props: { design: "editorial", theme: "light", run: "full" },
    },
    "dialog-dark": {
      note: "Shipped: Share poster… from the ••• menu (or ⌥⌘S). The preview is the exact image that is copied or saved; nothing leaves the Mac before Copy Image or Save…. Include share link is off.",
      props: { design: "glow", theme: "dark", run: "full", dialog: true },
    },
    "dialog-linked-light": {
      note: "Shipped: the dialog in light with Include share link on.",
      props: { design: "glow", theme: "light", run: "linked", dialog: true },
    },
  },
});
