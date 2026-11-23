// l10n-allow-file: gallery labels are fixture content, not shipped UI.
import { componentEntry } from "../gallery/format";
import { FloatingRoles } from "./FloatingRoles";

export default componentEntry<Record<string, never>>({
  id: "ui.floating-roles",
  title: "Floating roles",
  area: "UI primitives",
  height: 520,
  covers: ["ui/FloatingRoles.tsx", "ui/notice.css", "ui/popupSurface.css", "pages/shared/desktop.css"],
  load: async () => FloatingRoles,
  styles: () => Promise.all([import("./ui.css"), import("./FloatingRoles.gallery.css")]),
  variants: {
    all: {
      props: {},
      note: "Menu, popover, tooltip, toast and dialog with their measured corner, inset, height and nested corner, beside the --role-* token each reads (schemas/design-roles).",
    },
  },
});
