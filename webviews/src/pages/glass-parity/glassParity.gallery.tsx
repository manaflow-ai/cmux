// l10n-allow-file: the parity fixture's labels, not shipped UI.
// The Liquid Glass Parity page (main.tsx) outside the app: its fixture layout, one of each glass
// surface on the page's own glass (`css` mode), as `?mock` draws it for the browser dev loop. A menu
// cell holds a highlighted and a pressed row, as the App asks for its hover and pressed rows.
import { useEffect, useRef } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { ParityLayout, ParityRow } from "./main";

type Props = { row: ParityRow };

const drawn: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelectorAll(".glass-parity-surface").length === 7);
};

export default componentEntry<Props>({
  id: "pages.glass-parity",
  title: "Liquid Glass Parity",
  area: "Pages",
  height: 520,
  widths: { normal: 600 },
  covers: ["page:cmux.glass-parity", "pages/glass-parity/main.tsx"],
  load: async () => {
    const { PARITY_FIXTURE, renderParity } = await import("./main");
    return function GlassParityGallery({ row }: Props) {
      const root = useRef<HTMLDivElement>(null);
      useEffect(() => {
        const layout: ParityLayout = {
          ...PARITY_FIXTURE,
          cells: PARITY_FIXTURE.cells.map((cell) => (cell.kind === "menu" ? { ...cell, row } : cell)),
        };
        return renderParity(document, root.current!, layout, null);
      }, [row]);
      return <div ref={root} style={{ position: "relative", height: "100%" }} />;
    };
  },
  variants: {
    rest: {
      note: "Every surface at rest on the page's own glass: menu, popover, card, tooltip, dialog, toast and docked chrome.",
      props: { row: "rest" },
      play: drawn,
    },
    hover: {
      note: "The menu's row highlighted, as the App asks for its hover row.",
      props: { row: "hover" },
      play: drawn,
    },
    pressed: {
      note: "The menu's row highlighted and pressed.",
      props: { row: "pressed" },
      play: drawn,
    },
  },
});
