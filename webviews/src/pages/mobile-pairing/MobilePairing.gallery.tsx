// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { MobilePairingGalleryProps } from "./galleryFixture";

export default componentEntry<MobilePairingGalleryProps>({
  id: "pages.mobile-pairing",
  title: "Pair your iPhone",
  area: "Pages",
  height: 560,
  widths: { narrow: 420, normal: 600, wide: 760 },
  covers: [
    "page:cmux.mobile-pairing",
    "pages/mobile-pairing/MobilePairingPage.tsx#MobilePairingPage",
    "pages/mobile-pairing/galleryFixture.tsx",
  ],
  load: async () => (await import("./galleryFixture")).MobilePairingGallery,
  styles: async () => {
    await import("../../ui/ui.css");
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    "signed-out": {
      note: "A new user's first look: the line under the subtitle says where cmux on iPhone comes from (TestFlight beta) before any step.",
      props: { state: "signedOut" },
    },
    "access-off": {
      note: "Signed in, phone access off: the same line stays under the subtitle.",
      props: { state: "accessOff" },
    },
    ready: {
      note: "Ready with the pairing code: someone holding the code without the app still reads where to get it.",
      props: { state: "ready" },
    },
    "ready-no-code": {
      note: "Ready without a code: the host's how-to-connect line, with the get-the-app line above the steps.",
      props: { state: "readyNoCode" },
    },
  },
});
