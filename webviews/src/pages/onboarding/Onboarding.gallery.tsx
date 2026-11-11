// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { OnboardingGalleryProps } from "./galleryFixture";

export default componentEntry<OnboardingGalleryProps>({
  id: "pages.onboarding",
  title: "Onboarding",
  area: "Home and Chief",
  height: 520,
  widths: { narrow: 520, normal: 640, wide: 760 },
  covers: [
    "page:cmux.onboarding",
    "pages/onboarding/Onboarding.tsx",
    "pages/onboarding/AgentsStep.tsx",
    "pages/onboarding/ImportStep.tsx",
    "pages/onboarding/ComputerUseStep.tsx",
    "pages/onboarding/galleryFixture.tsx",
  ],
  load: async () => (await import("./galleryFixture")).OnboardingGallery,
  styles: async () => {
    await import("../../ui/ui.css");
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    // The agents list, three looks (the variant switch): list ships.
    "agents-list": {
      note: "Recommended (default): one card, a row per agent, hairlines between, as Settings' lists. Quiet, scales to many agents in the fixed window.",
      props: { step: "agents", agents: "mixed", look: "list" },
    },
    "agents-cards": {
      note: "The Swift step's look: a rounded card per agent, the name in the title size.",
      props: { step: "agents", agents: "mixed", look: "cards" },
    },
    "agents-compact": {
      note: "Compact rows on the glass, the sign-in state as a pill and Sign In as a quiet button.",
      props: { step: "agents", agents: "mixed", look: "compact" },
    },
    "agents-checking": { props: { step: "agents", agents: "checking" } },
    "agents-signing-in": { props: { step: "agents", agents: "signingIn" } },
    "agents-sign-in-failed": { props: { step: "agents", agents: "failed" } },
    "agents-none": { props: { step: "agents", agents: "none" } },
    "agents-install": {
      note: "Install offers: idle with the vendor's page, installing with its step, failed with the installer's text.",
      props: { step: "agents", agents: "install" },
    },
    "agents-install-cards": { props: { step: "agents", agents: "install", look: "cards" } },
    "agents-install-compact": { props: { step: "agents", agents: "install", look: "compact" } },
    // The import step, Express (docs/design/onboarding-import-express.md) on the worst list.
    "import-crowded": {
      note: "Express: the checked browsers' icons, one sentence, the kinds, the grant asks; Choose Browsers and Data… opens the full list.",
      props: { step: "importData", importer: "crowded" },
    },
    "import-idle": { props: { step: "importData", importer: "idle" } },
    "import-detecting": { props: { step: "importData", importer: "detecting" } },
    "import-ready": {
      note: "Targets on checked rows, a profile that needs Full Disk Access, a browser awaiting its folder grant.",
      props: { step: "importData", importer: "ready" },
    },
    "import-none": { props: { step: "importData", importer: "noBrowsers" } },
    "import-importing": { props: { step: "importData", importer: "importing" } },
    "import-finished": { props: { step: "importData", importer: "finished" } },
    "import-failed": { props: { step: "importData", importer: "failed" } },
    "import-access": { props: { step: "importData", importer: "access" } },
    "import-access-refused": { props: { step: "importData", importer: "accessRefused" } },
    "import-consent": { props: { step: "importData", importer: "consent" } },
    "import-consent-firefox": { props: { step: "importData", importer: "consentFirefox" } },
    "import-denied": { props: { step: "importData", importer: "denied" } },
    "computer-use-fresh": { props: { step: "computerUse", computerUse: "fresh" } },
    "computer-use-one-granted": { props: { step: "computerUse", computerUse: "oneGranted" } },
    "computer-use-all-granted": { props: { step: "computerUse", computerUse: "allGranted" } },
    "computer-use-helper-failed": { props: { step: "computerUse", computerUse: "helperFailed" } },
    "computer-use-off": { props: { step: "computerUse", computerUse: "off" } },
    "computer-use-unavailable": { props: { step: "computerUse", computerUse: "unavailable" } },
  },
});
