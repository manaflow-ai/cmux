// l10n-allow-file: public-safe gallery fixtures, not shipped copy.
import { componentEntry } from "../../../gallery/format";
import type { AutoSizeWarningProps } from "./AutoSizeWarning";
import type { AutoSizeWarning as AutoSizeWarningModel } from "./autoSizeWarningModel";

const labels = {
  title: "This build may be too large for this machine",
  resizeNow: "Resize now",
  runOnBuildMachine: "Run it on a build machine",
  carryOn: "Carry on",
};

const chromium: AutoSizeWarningModel = {
  command: "fetch --nohooks chromium && autoninja -C out/Default chrome",
  project: "chromium",
  short: ["disk", "memory"],
  needsDisk: 100_000_000_000,
  needsMemory: 16_000_000_000,
  text: "Chromium needs 100 GB of disk and 16 GB of memory; this machine has 20 GB free and 4 GB. About 20 hours here if it fit, about 1.5 hours and $3 on 32 vCPU.",
};

const llvm: AutoSizeWarningModel = {
  command: "cmake -S llvm-project/llvm -B build -G Ninja",
  project: "llvm",
  short: ["disk"],
  needsDisk: 20_000_000_000,
  text: "LLVM needs more free disk than this machine has. Run it on a larger machine to keep this chat moving.",
};

const cargo: AutoSizeWarningModel = {
  command: "cargo build --release",
  short: ["disk", "memory"],
  needsDisk: 40 * 1_073_741_824,
  needsMemory: 3 * 1_073_741_824,
  text: "This build wants more than this machine has: `cargo build --release` in a 40 GiB checkout, with 3.0 GiB of memory free on 2 vCPUs.",
};

const rustc: AutoSizeWarningModel = {
  command: "x.py build library/std",
  project: "rustc",
  short: ["memory"],
  needsMemory: 8_000_000_000,
  text: "rustc needs more memory than this machine has. Resize now, run it on a build machine, or carry on here.",
};

const props = (warning: AutoSizeWarningModel): AutoSizeWarningProps => ({
  warning,
  labels,
  onResizeNow() {},
  onRunOnBuildMachine() {},
  onCarryOn() {},
});

export default componentEntry<AutoSizeWarningProps>({
  id: "agent-pane.autosize-warning",
  title: "AutoSize known-heavy warning",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 360, normal: 620, wide: 820 },
  covers: ["agent-session/acpmux/autoSize/AutoSizeWarning.tsx#AutoSizeWarning"],
  styles: () => import("./autoSizeWarning.css"),
  load: () => import("./AutoSizeWarning").then((module) => module.AutoSizeWarning),
  variants: {
    chromium: {
      note: "A known Chromium build is short on both disk and memory. The warning keeps the complete Rust explanation and all three RFD 0133 actions.",
      props: props(chromium),
    },
    llvm: {
      note: "An LLVM build is short on disk only. The same row stays compact when the precheck reports one shortage.",
      props: props(llvm),
    },
    "large-cargo": {
      note: "A generic large checkout has no named project. The warning still identifies the command and explains the machine limits.",
      props: props(cargo),
    },
    rustc: {
      note: "A rustc build is short on memory only, showing the project-specific payload shape.",
      props: props(rustc),
    },
  },
});
