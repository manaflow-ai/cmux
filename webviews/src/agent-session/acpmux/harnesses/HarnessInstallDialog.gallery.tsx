// l10n-allow-file: gallery fixtures name harnesses and the output their installers print.
import { componentEntry } from "../../../gallery/format";
import { INSTALL_COMMANDS } from "./harnessRows";
import type { HarnessInstallPhase, HarnessInstallTarget } from "./useHarnessInstall";

const gemini: HarnessInstallTarget = {
  harness: "gemini",
  name: "Gemini CLI",
  mark: "gemini",
  command: INSTALL_COMMANDS.gemini,
  docsUrl: "https://github.com/google-gemini/gemini-cli",
};

type Props = { target?: HarnessInstallTarget; phase?: HarnessInstallPhase };

/// The model picker's install prompt (cmux#38191): a model of Gemini CLI, which this Mac does not
/// have, was picked.
export default componentEntry<Props>({
  id: "agent-pane.harness-install",
  title: "Model picker install prompt",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 360, normal: 560, wide: 760 },
  covers: ["agent-session/acpmux/harnesses/HarnessInstallDialog.tsx#HarnessInstallDialog"],
  load: async () => {
    const { HarnessInstallDialog } = await import("./HarnessInstallDialog");
    return ({ target = gemini, phase = { kind: "confirm" } }: Props) => (
      <HarnessInstallDialog
        state={{ target, phase, open: true }}
        onInstall={() => undefined}
        onCancel={() => undefined}
        {...(target.docsUrl ? { onSetupGuide: () => undefined } : {})}
      />
    );
  },
  styles: () =>
    Promise.all([
      import("../../../ui/ui.css"),
      import("../../../ui/popupSurface.css"),
      import("../styles.css"),
      import("./harnesses.css"),
    ]),
  variants: {
    confirm: { note: "Install or Cancel, with the command Install runs.", props: {} },
    installing: {
      note: "The command runs: its last output line is the progress; Hide leaves it running.",
      props: { phase: { kind: "installing", line: "added 214 packages in 6s" } },
    },
    failed: {
      note: "The command failed: its last line says why, with the setup page and Try Again.",
      props: {
        phase: { kind: "failed", reason: "npm error permission denied, mkdir '/usr/local/lib/node_modules'" },
      },
    },
    "no-installer": {
      note: "A harness with no one-click installer offers only its setup page.",
      props: {
        target: { harness: "pi", name: "Pi", mark: "pi", docsUrl: "https://github.com/earendil-works/pi" },
      },
    },
  },
});
