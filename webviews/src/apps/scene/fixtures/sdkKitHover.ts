// l10n-allow-file: deterministic SDK scene test and gallery fixture, not shipped UI.
import type { SceneOp } from "../store";

/** Real SDK scene node types, through SceneStore/SceneRenderer and the shared Instrument kit. */
export const sdkKitHover: SceneOp[] = [
  { op: "create", id: "sdk-root", type: "VStack", props: { spacing: 24 } },
  {
    op: "create",
    id: "sdk-tip",
    type: "Tooltip",
    props: { text: "Open the latest run", side: "bottom" },
  },
  {
    op: "create",
    id: "sdk-pill",
    type: "Pill",
    props: { text: "3 passed", tone: "success", size: "sm" },
  },
  { op: "children", id: "sdk-tip", children: ["sdk-pill"] },
  { op: "create", id: "sdk-card", type: "Card", props: { side: "inline-end" } },
  { op: "create", id: "sdk-trigger", type: "Button", props: { title: "Inspect run" } },
  { op: "create", id: "sdk-detail", type: "Text", props: { text: "Last run passed" } },
  { op: "create", id: "sdk-action", type: "Button", props: { title: "Copy run link" } },
  { op: "children", id: "sdk-card", children: ["sdk-trigger", "sdk-detail", "sdk-action"] },
  { op: "children", id: "sdk-root", children: ["sdk-tip", "sdk-card"] },
  { op: "root", id: "sdk-root" },
];
