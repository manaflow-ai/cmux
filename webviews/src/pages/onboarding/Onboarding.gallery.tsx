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
    "pages/onboarding/MakeItYoursStep.tsx",
    "pages/onboarding/galleryFixture.tsx",
    "pages/onboarding/signInReadiness.ts",
    "pages/shared/signIn/ProviderReadiness.tsx",
    "pages/shared/signIn/useAccountSignIn.ts",
    "pages/shared/signIn/mockSignIn.ts",
    "pages/shared/signIn/galleryFixtures.ts#READINESS",
  ],
  load: async () => (await import("./galleryFixture")).OnboardingGallery,
  styles: async () => {
    await import("../../ui/ui.css");
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    // Make cmux Yours (cmux#48416), five looks (the variant switch): preview ships.
    "make-it-yours-preview": {
      note: "Recommended (default): a small cmux window drawn from the three answers on the left (the painting behind, a chat or a terminal, rows as tight as the density), the choices on the right: work styles as one list with radio dots, density as one segmented track, backgrounds as unnamed tiles with the chosen work named under the window.",
      props: { step: "makeItYours", makeItYours: "fresh", makeLook: "preview" },
    },
    "make-it-yours-preview-picked": {
      props: { step: "makeItYours", makeItYours: "picked", makeLook: "preview" },
    },
    "make-it-yours-preview-terminal": {
      props: { step: "makeItYours", makeItYours: "terminal", makeLook: "preview" },
    },
    "make-it-yours-segmented": {
      note: "The cards' layout, calmer: Recommended as quiet text, density as one segmented track, unnamed tiles with the chosen work's whole name under the row.",
      props: { step: "makeItYours", makeItYours: "picked", makeLook: "segmented" },
    },
    "make-it-yours-form": {
      note: "A Settings pane: each question on the left, its control on the right.",
      props: { step: "makeItYours", makeItYours: "picked", makeLook: "form" },
    },
    "make-it-yours-cards": {
      note: "The first look (#48514): Agents First and Terminal First as two cards with a line each, density as three buttons, backgrounds as named tiles.",
      props: { step: "makeItYours", makeItYours: "fresh", makeLook: "cards" },
    },
    "make-it-yours-rows": {
      note: "Quieter: the same three choices as settings rows, the work styles without their lines, the backgrounds as unnamed swatches.",
      props: { step: "makeItYours", makeItYours: "fresh", makeLook: "rows" },
    },
    "make-it-yours-picked": { props: { step: "makeItYours", makeItYours: "picked" } },
    "make-it-yours-terminal": { props: { step: "makeItYours", makeItYours: "terminal" } },
    "make-it-yours-loading": { props: { step: "makeItYours", makeItYours: "loading" } },
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
    // Provider readiness (logins done right) in the one agents list: Claude Code and Codex take their
    // provider's state and one action in place, GitHub is one more row. Each variant is what a host
    // sends (`signInReadiness`, `signInAccounts`) and what its sign-in answers through the mock's
    // `cmux.onboarding.accounts.run`: not installed, installing, sign-in required, signing in with
    // the code, ready, failed.
    "agents-readiness-fresh": {
      note: "First run: GitHub and Claude Code need a sign-in (Sign In), Codex is not installed (Install).",
      props: { step: "agents", agents: "mixed", readiness: "fresh" },
    },
    "agents-readiness-signing-in": {
      note: "Codex signing in (started through the op, its finish held): the code is in its own row; the page is open beside the window.",
      props: { step: "agents", agents: "mixed", readiness: "signingIn" },
    },
    "agents-readiness-mixed": {
      note: "GitHub ready, Codex installing (no button: it only waits), Claude Code's sign-in refused (cancelled on the provider's page) with Try Again.",
      props: { step: "agents", agents: "mixed", readiness: "mixed" },
    },
    "agents-readiness-ready": {
      note: "All three ready: each offers Add Account for another personal account.",
      props: { step: "agents", agents: "mixed", readiness: "ready" },
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
    "computer-use-finished": {
      note: "The person's Allow got the last grant on: the done view, which closes the window after 2.4 s.",
      props: { step: "computerUse", computerUse: "finished" },
    },
    "computer-use-confirming-capture": {
      note: "Screenshots was just allowed: macOS asks once more the first time it captures.",
      props: { step: "computerUse", computerUse: "confirmingCapture" },
    },
    "computer-use-helper-failed": { props: { step: "computerUse", computerUse: "helperFailed" } },
    "computer-use-off": { props: { step: "computerUse", computerUse: "off" } },
    "computer-use-unavailable": { props: { step: "computerUse", computerUse: "unavailable" } },
  },
});
