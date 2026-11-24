// l10n-allow-file: gallery fixtures, not shipped UI.
// The four AutoCloud status icon designs, every state, one sheet (Spaces off, then Spaces on).
import { componentEntry } from "../gallery/format";
import type { AutoCloudStatusMatrixProps } from "./AutoCloudStatus";

export default componentEntry<AutoCloudStatusMatrixProps>({
  id: "sidebar.autocloud-status-matrix",
  title: "AutoCloud status icon: all designs, all states",
  area: "Sidebar",
  experimental: true,
  covers: ["sidebar/AutoCloudStatus.tsx#AutoCloudMatrix"],
  height: 520,
  keywords: ["autocloud", "presence", "sync", "matrix"],
  load: () => import("./AutoCloudStatus").then((module) => module.AutoCloudMatrix),
  variants: {
    "spaces-off": { note: "Spaces hidden (the default)", props: {} },
    "spaces-on": { note: "Spaces on: the dots strip shares the row", props: { spaces: true } },
  },
});
