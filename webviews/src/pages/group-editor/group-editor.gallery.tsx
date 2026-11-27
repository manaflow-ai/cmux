// l10n-allow-file: gallery fixtures (public-safe group editor sessions), not shipped UI.
// The workspace group editor (cmux-page://cmux.group-editor/): the page's own mount over the mock
// host, in a 240 wide glass card standing in for the native bubble's (SidebarGroupEditor.swift).
// Chosen: V1 (`v1-native`), the AppKit editor's look reproduced; the page ships it. V2 and V3 are
// the alternatives it was weighed against.
import { useEffect, useRef } from "react";
import { componentEntry } from "../../gallery/format";
import type { GroupEditorLayout } from "./GroupEditor";
import { fixtureSession, type FixtureOptions } from "./fixtures";

type Props = FixtureOptions & { layout?: GroupEditorLayout; type?: string };

function GroupEditorGallery(props: Props) {
  const host = useRef<HTMLDivElement>(null);
  // Every prop: a new variant mounts a new editor.
  const key = JSON.stringify(props);
  useEffect(() => {
    const root = host.current;
    if (!root) return;
    const { layout = "native", type, ...fixture } = JSON.parse(key) as Props;
    let dispose = () => {};
    let live = true;
    void Promise.all([import("./mount"), import("./mockHost")]).then(
      ([{ mountGroupEditor }, { MockGroupEditorHost }]) => {
        if (!live) return;
        const session = fixtureSession(fixture);
        const editor = mountGroupEditor(root, new MockGroupEditorHost(session), { layout });
        dispose = editor.unmount;
        // Drawn now, not after the mock's stream answers, so the stage's first frame has the card.
        editor.open(session);
        // A typed name: the field after the person typed, before they close.
        if (type === undefined) return;
        const field = root.querySelector<HTMLInputElement>("input");
        if (!field) return;
        field.value = type;
        field.dispatchEvent(new Event("input", { bubbles: true }));
      },
    );
    return () => {
      live = false;
      dispose();
    };
  }, [key]);
  return (
    <div className="group-editor-gallery">
      <div className="ui-glass group-editor-gallery-card" ref={host} />
    </div>
  );
}

export default componentEntry<Props>({
  id: "pages.group-editor",
  title: "Workspace group editor",
  area: "Pages",
  height: 420,
  widths: { narrow: 280, normal: 360, wide: 480 },
  covers: ["page:cmux.group-editor", "pages/group-editor/GroupEditor.tsx"],
  keywords: ["group", "bubble", "rename", "color", "tab group"],
  load: async () => GroupEditorGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
    await import("./group-editor.gallery.css");
  },
  variants: {
    // Chosen: V1 ships.
    "v1-native": {
      note: "V1 (chosen, ships): the native bubble reproduced. One row of 18 dots spread across the card, 24 rows with icons and trailing values.",
      props: {},
    },
    "v2-grid-dots": {
      note: "V2: the dots on a six-column grid at 24, two rows; bigger targets, one row taller.",
      props: { layout: "grid" },
    },
    "v3-plain-rows": {
      note: "V3: rows without icons at the menu row height; quieter, but the actions lose their marks.",
      props: { layout: "plain", icons: false },
    },
    "no-color": { note: "No color: the grey dot carries the ring.", props: { chosen: null } },
    "custom-chosen": {
      note: "A custom color: the custom dot shows it with the ring; no palette dot is ringed.",
      props: { chosen: "custom" },
    },
    "long-name": {
      note: "A name longer than the field: it scrolls in the field, the card keeps its width.",
      props: { name: "Platform migration and release coordination for the autumn launch" },
    },
    "sort-manual": {
      note: "The Sort row shows its value, Manual, in the shortcut slot.",
      props: { chosen: "green" },
    },
    pinned: { note: "A pinned group: the pin row reads Unpin Group.", props: { pinned: true, chosen: "purple" } },
    typed: { note: "The person typed a new name (a draft) before closing.", props: { type: "Design review" } },
    empty: { note: "A new group with no name yet: the placeholder.", props: { name: "", chosen: null } },
  },
});
