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
    "pages/onboarding/walkArms.tsx",
    "pages/onboarding/walk.ts",
    "pages/onboarding/walkLook.tsx",
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
    // The intro walk's arms only: the shipped page never loads this sheet.
    await import("./walkArms.css");
  },
  variants: {
    // Make cmux Yours (cmux#48416), two looks (the variant switch): cards ships.
    "make-it-yours-cards": {
      note: "Recommended (default): Agents First and Terminal First as two cards with a line each (Agents First marked Recommended), density as three segments, backgrounds as named tiles.",
      props: { step: "makeItYours", makeItYours: "fresh", makeLook: "cards" },
    },
    "make-it-yours-rows": {
      note: "Quieter: the same three choices as settings rows, the work styles without their lines, the backgrounds as unnamed swatches.",
      props: { step: "makeItYours", makeItYours: "fresh", makeLook: "rows" },
    },
    "make-it-yours-picked": { props: { step: "makeItYours", makeItYours: "picked" } },
    "make-it-yours-terminal": { props: { step: "makeItYours", makeItYours: "terminal" } },
    "make-it-yours-loading": { props: { step: "makeItYours", makeItYours: "loading" } },
    // experiments.introWalk on (off by default): Make cmux Yours as the intro walk's four screens (hq RFD 0057).
    "intro-walk-look": {
      note: "Screen 1 of 4: five whole looks, each with its light and dark face; House (what you have) checked. Tidy off.",
      props: { step: "makeItYours", makeItYours: "fresh", introWalk: true, makeScreen: "look" },
    },
    "intro-walk-work": {
      note: "Screen 2 of 4: how you work, Agents First checked.",
      props: { step: "makeItYours", makeItYours: "fresh", introWalk: true, makeScreen: "work" },
    },
    "intro-walk-trust": {
      note: "Screen 3 of 4: what agents may do, each mode explained, Full Access (as shipped) checked; banners and sound.",
      props: { step: "makeItYours", makeItYours: "fresh", introWalk: true, makeScreen: "trust" },
    },
    "intro-walk-tune": {
      note: "Screen 4 of 4: density, asked only here, and the background rows; a person's own picks checked.",
      props: { step: "makeItYours", makeItYours: "picked", introWalk: true, makeScreen: "tune" },
    },
    // The intro walk (Make cmux Yours, round 2): every contested screen as arms to pick between, all
    // [taste]. Gallery only: the shipped first-run screen is `make-it-yours-cards` above, unchanged.
    "walk-look-a-grid": {
      note: "Pick a look, A: a 2x2-plus grid of large whole-app tiles, each with its light and dark face. House (today's look) is picked.",
      props: { step: "makeItYours", walk: { screen: "look", layout: "grid" } },
    },
    "walk-look-b-hero": {
      note: "Pick a look, B: the picked bundle as one tall hero over a strip of the five.",
      props: { step: "makeItYours", walk: { screen: "look", layout: "hero", picked: "glasshouse" } },
    },
    "walk-look-c-list": {
      note: "Pick a look, C: a compact list, a small preview and one line each.",
      props: { step: "makeItYours", walk: { screen: "look", layout: "list" } },
    },
    "walk-trust-a-rows": {
      note: "Trust and noise, A: two segmented rows (agents may: Ask / Standard / Full access; notifications: Quiet / Banners / Banners and sound), one example line under each pick. The shipped values are picked.",
      props: { step: "makeItYours", walk: { screen: "trust", layout: "rows" } },
    },
    "walk-trust-b-cards": {
      note: "Trust and noise, B: three whole cards for the permission, noise as a row under.",
      props: { step: "makeItYours", walk: { screen: "trust", layout: "cards" } },
    },
    "walk-trust-c-more": {
      note: "Trust and noise, C: folded into the look screen as a More disclosure (closed).",
      props: { step: "makeItYours", walk: { screen: "look", layout: "list", more: true } },
    },
    "walk-trust-c-more-open": {
      note: "Trust and noise, C, with More open: the look list then scrolls inside the window.",
      props: { step: "makeItYours", walk: { screen: "look", layout: "list", more: true, open: true } },
    },
    "walk-tune-a-three": {
      note: "Tune, A: density as three levels, More shows the outer two; then today's background, opacity and material rows.",
      props: { step: "makeItYours", makeItYours: "picked", walk: { screen: "tune", layout: "three" } },
    },
    "walk-tune-a-three-more": {
      note: "Tune, A, with More: all five levels in the same track.",
      props: { step: "makeItYours", makeItYours: "picked", walk: { screen: "tune", layout: "three", more: true } },
    },
    "walk-tune-b-five": {
      note: "Tune, B: all five density levels (today's shape, cmux#49701) and the same rows.",
      props: { step: "makeItYours", makeItYours: "picked", walk: { screen: "tune", layout: "five" } },
    },
    "walk-tune-c-two-tone": {
      note: "Tune, C: density as three plus a Two-tone switch row (off, as shipped).",
      props: { step: "makeItYours", makeItYours: "picked", walk: { screen: "tune", layout: "twoTone" } },
    },
    "walk-exit-a-chat": {
      note: "The exit, A: Continue lands in a new chat, composer focused, one suggested prompt (the destination as a still).",
      props: { step: "makeItYours", walk: { screen: "exit", layout: "chat" } },
    },
    "walk-exit-b-summary": {
      note: "The exit, B: what was picked, Undo All, and the replay line.",
      props: {
        step: "makeItYours",
        makeItYours: "picked",
        walk: { screen: "exit", layout: "summary", picked: "glasshouse" },
      },
    },
    "walk-exit-c-try-it": {
      note: "The exit, C: Try it: open the palette (done), start one agent.",
      props: { step: "makeItYours", walk: { screen: "exit", layout: "tryIt" } },
    },
    "walk-footer-today": {
      note: "Footer, today: Skip and Continue.",
      props: { step: "makeItYours", walk: { screen: "look", layout: "grid", history: 2 } },
    },
    "walk-footer-undo-redo": {
      note: "Footer, variant: a persistent Undo / Redo pair leading, Skip and Continue trailing. Two picks made, so Undo is live.",
      props: { step: "makeItYours", walk: { screen: "look", layout: "grid", history: 2, footer: "undoRedo" } },
    },
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
    "computer-use-helper-failed": { props: { step: "computerUse", computerUse: "helperFailed" } },
    "computer-use-off": { props: { step: "computerUse", computerUse: "off" } },
    "computer-use-unavailable": { props: { step: "computerUse", computerUse: "unavailable" } },
  },
});
