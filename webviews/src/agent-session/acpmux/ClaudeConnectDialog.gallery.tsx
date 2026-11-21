// l10n-allow-file: synthetic gallery fixtures (sample token, label and refusal), not shipped UI.
import { componentEntry } from "../../gallery/format";

type Props = {
  /// `rest`, `invalid`, `verifying` and `failed` open in that state; `refuses` turns a submit down.
  start?: { token?: string; label?: string; pending?: boolean; error?: string };
  refuses?: string;
};

export default componentEntry<Props>({
  id: "agent-pane.claude-connect-dialog",
  title: "Picker Connect your Claude subscription",
  area: "Agent pane",
  pane: true,
  height: 560,
  widths: { narrow: 360, normal: 560, wide: 820 },
  covers: ["agent-session/acpmux/ClaudeConnectDialog.tsx#ClaudeConnectDialog"],
  load: async () => {
    const { ClaudeConnectDialog } = await import("./ClaudeConnectDialog");
    return function GalleryClaudeConnect({ start, refuses }: Props) {
      return (
        <ClaudeConnectDialog
          add={(_token) =>
            refuses
              ? Promise.reject(new Error(refuses))
              : // Verifying holds until the frame is captured.
                new Promise<void>(() => undefined)
          }
          onClose={() => undefined}
          onConnected={() => undefined}
          {...(start ? { start } : {})}
        />
      );
    };
  },
  styles: () => Promise.all([import("./styles.css"), import("../../ui/ui.css"), import("../../ui/popupSurface.css")]),
  variants: {
    rest: { props: {} },
    invalid: { props: { start: { token: "sk-ant-api03 not a setup token" } } },
    ready: { props: { start: { token: "sk-ant-oat01-0123456789abcdef", label: "alex@example.com" } } },
    verifying: { props: { start: { label: "alex@example.com", pending: true } } },
    failed: {
      props: {
        start: {
          label: "alex@example.com",
          error: "Couldn’t connect: Claude refused this token (401). Run claude setup-token again.",
        },
        refuses: "Claude refused this token (401). Run claude setup-token again.",
      },
    },
  },
});
