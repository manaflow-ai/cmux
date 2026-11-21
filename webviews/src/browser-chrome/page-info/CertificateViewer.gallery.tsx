// l10n-allow-file: gallery fixtures (sample certificates), not shipped UI.
// Page Info's certificate viewer over a sample chain (leaf, intermediate, root), dates in UTC so
// every capture reads the same.
import { componentEntry } from "../../gallery/format";
import { CertificateViewer, type CertificateViewerLook } from "./CertificateViewer";
import { certificateChain, certificateFailure, noCertificate } from "./windowFixtures";
import type { CertificateState } from "./windows";

type Props = { state: CertificateState; look?: CertificateViewerLook };

function CertificateFixture({ state, look }: Props) {
  return (
    <div style={{ width: 520 }}>
      <CertificateViewer state={state} look={look} onCommand={() => {}} format={{ timeZone: "UTC" }} />
    </div>
  );
}

export default componentEntry<Props>({
  id: "browser-chrome.page-info.certificate",
  title: "Page Info: Certificate viewer",
  area: "Browser chrome",
  experimental: true,
  height: 640,
  widths: { narrow: 540, normal: 580, wide: 660 },
  covers: ["browser-chrome/page-info/CertificateViewer.tsx"],
  keywords: ["certificate", "tls", "ssl", "fingerprint", "x509", "export"],
  load: async () => CertificateFixture,
  options: [
    {
      id: "look",
      label: "Look",
      kind: "choice",
      choices: [
        { value: "list", label: "List" },
        { value: "tabs", label: "Tabs" },
        { value: "sheet", label: "Sheet" },
      ],
      defaultValue: "list",
    },
  ],
  variants: {
    list: {
      props: { state: certificateChain },
      note: "Recommended look: General and Details tabs, Details listing every field with its value.",
    },
    tabs: {
      props: { state: certificateChain, look: "tabs" },
      note: "Today's native viewer: pick a field to read its value.",
    },
    sheet: { props: { state: certificateChain, look: "sheet" }, note: "Everything on one scrolling sheet." },
    failure: { props: { state: certificateFailure }, note: "The engine's reason, in danger ink." },
    empty: { props: { state: noCertificate } },
  },
});
