// l10n-allow-file: gallery fixtures (synthetic names), not shipped UI.
import { componentEntry } from "../../gallery/format";

export default componentEntry({
  id: "pages.home-channels.avatar-initials",
  title: "Home name initials",
  area: "Home and Chief",
  height: 320,
  covers: ["pages/home-channels/Avatar.tsx#Avatar", "pages/home-channels/AvatarInitialsDemo.tsx#AvatarInitialsDemo"],
  load: async () => (await import("./AvatarInitialsDemo")).AvatarInitialsDemo,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
    await import("./ledger.css");
  },
  variants: {
    names: {
      note: "Real Home avatars without pictures at their 20px and 24px sizes, beside the original synthetic names.",
      props: {},
    },
  },
});
