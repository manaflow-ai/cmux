// l10n-allow-file: gallery fixture labels and synthetic addresses.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { ContactGalleryProps } from "./components/ChiefContactGallery";

const request: Play = async (ctx) => {
  const input = { selector: "#chief-contact-handle" };
  await ctx.waitFor(() => ctx.find(input));
  await ctx.waitFor(() => !ctx.find(input).hasAttribute("disabled"));
  await ctx.type("+1 555 555 0123", input);
  await ctx.click({ selector: '.chief-contact-form button[type="submit"]' });
};

export default componentEntry<ContactGalleryProps>({
  id: "settings.chief-contact",
  title: "Contact your Chief anywhere",
  area: "Settings",
  height: 700,
  widths: { narrow: 360, normal: 560, wide: 800 },
  covers: ["pages/settings/components/ChiefContactSheet.tsx#ChiefContactSheet"],
  load: async () => (await import("./components/ChiefContactGallery")).default,
  styles: () =>
    Promise.all([
      import("../shared/desktop.css"),
      import("../../ui/ui.css"),
      import("../../ui/popupSurface.css"),
      import("./styles.css"),
      import("./chiefContact.css"),
    ]),
  variants: {
    balanced: { props: { layout: "balanced" } },
    compact: { props: { layout: "compact" } },
    roomy: { props: { layout: "roomy" } },
    sending: { props: { sending: true }, play: request },
    waiting: { props: { state: "waiting" } },
    linked: { props: { state: "linked" } },
    "rate-limited": { props: { requestError: "link.rate_limited" }, play: request },
    "bound-elsewhere": { props: { requestError: "link.bound_elsewhere" }, play: request },
    stopped: { props: { state: "stopped" } },
  },
});
