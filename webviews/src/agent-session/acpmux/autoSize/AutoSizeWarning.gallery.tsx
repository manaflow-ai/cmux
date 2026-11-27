// l10n-allow-file: public-safe gallery fixtures, not shipped copy.
import { componentEntry } from "../../../gallery/format";
import type { AutoSizeWarningProps } from "./AutoSizeWarning";
import type { AutoSizeWarning as AutoSizeWarningModel } from "./autoSizeWarningModel";

const labels = {
  title: "Sized for this build",
  dismiss: "Dismiss",
};

// Texts are what `heavy_precheck::notice` and the run VM sizing notice print.
const chromium: AutoSizeWarningModel = {
  command: "autoninja -C out/Default chrome",
  project: "chromium",
  short: ["disk", "memory"],
  needsDisk: 100_000_000_000,
  needsMemory: 16_000_000_000,
  text: "Chromium needs 100 GB of disk and 16 GB of memory; this machine has 20 GB free and 4 GB. Running it on a run VM with 8 vCPU and 16 GiB, sized from Chromium's published memory minimum.",
};

const rustc: AutoSizeWarningModel = {
  command: "x.py build library/std",
  project: "rustc",
  short: ["memory"],
  needsMemory: 8_000_000_000,
  text: "rustc needs 8 GB of memory; this machine has 4 GB. Running it here; this machine grows as it works.",
};

const cargo: AutoSizeWarningModel = {
  command: "cargo build --release",
  short: ["disk"],
  needsDisk: 40 * 1_073_741_824,
  text: "`cargo build --release` in a 40 GiB checkout wants more free disk than this machine has. Running it here as it is.",
};

const props = (warning: AutoSizeWarningModel, look: AutoSizeWarningProps["look"]): AutoSizeWarningProps => ({
  warning,
  labels,
  look,
  onDismiss() {},
});

export default componentEntry<AutoSizeWarningProps>({
  id: "agent-pane.autosize-warning",
  title: "AutoSize notice row (RFD 0144 piece 8)",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 360, normal: 620, wide: 820 },
  covers: ["agent-session/acpmux/autoSize/AutoSizeWarning.tsx#AutoSizeWarning"],
  styles: () => import("./autoSizeWarning.css"),
  load: () => import("./AutoSizeWarning").then((module) => module.AutoSizeWarning),
  variants: {
    "card-chromium": {
      note: "A. Card: an inline notice card, no buttons. Chromium moved to a run VM sized from its published minimum.",
      props: props(chromium, "card"),
    },
    "line-chromium": {
      note: "B. Line: one quiet transcript line with an accent dot, no card. Same Chromium text.",
      props: props(chromium, "line"),
    },
    "dismissible-chromium": {
      note: "C. Dismissible: the card with an ×, still no actions. Same Chromium text.",
      props: props(chromium, "dismissible"),
    },
    "line-rustc-here": {
      note: "B on rustc kept here with AutoCloud's grow-as-it-works.",
      props: props(rustc, "line"),
    },
    "card-cargo-as-is": {
      note: "A on a generic cargo build kept here as it is (no named project, AutoCloud off).",
      props: props(cargo, "card"),
    },
  },
});
