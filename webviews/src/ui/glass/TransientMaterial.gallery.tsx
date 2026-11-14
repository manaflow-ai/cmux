// l10n-allow-file: material gallery fixtures, not shipped UI.
// Web material evidence only; native Mac/iOS galleries show their real system materials.
import { type CSSProperties } from "react";
import { componentEntry } from "../../gallery/format";
import { Notice } from "../Notice";
import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import "../../pages/shared/transientMaterial.css";

type Look = "before" | "standard" | "quieter" | "denser";
type Props = { look: Look; scheme: "light" | "dark" };

function TransientMaterialGallery({ look, scheme }: Props) {
  const before = look === "before";
  const veil = look === "quieter" ? "32%" : look === "denser" ? "64%" : scheme === "dark" ? "42%" : "55%";
  const menu = look === "quieter" ? "70%" : look === "denser" ? "86%" : "var(--ds-transient-web-tint)";
  const fill = (opacity: string) => `color-mix(in srgb, var(--glass-surface) ${opacity}, transparent)`;
  const surface = {
    position: "relative",
    inset: "auto",
    margin: 0,
    width: "100%",
    padding: "var(--ds-space-3)",
    "--glass-tint": fill(menu),
    "--glass-backdrop": "blur(var(--ds-transient-web-blur)) saturate(var(--ds-transient-web-saturation))",
  } as CSSProperties;
  const sheet = {
    ...surface,
    "--glass-backdrop": before
      ? "var(--surface-blur)"
      : "blur(var(--ds-transient-web-blur)) saturate(var(--ds-transient-web-saturation))",
    "--glass-tint": before
      ? `color-mix(in srgb, var(--ds-material-neutral-${scheme}) ${scheme === "dark" ? "48%" : "62%"}, transparent)`
      : fill(veil),
  } as CSSProperties;
  return (
    <div
      className="transient-material-scope"
      style={
        {
          colorScheme: scheme,
          padding: "var(--ds-space-6)",
          minHeight: 500,
          background: `url("${wallpaper}") center / cover`,
          color: "var(--cmux-text)",
          "--cmux-text": scheme === "dark" ? "rgb(240 240 242)" : "rgb(26 26 29)",
          "--glass-surface": scheme === "dark" ? "rgb(28 28 30)" : "rgb(252 252 252)",
          "--transient-surface-veil": fill(veil),
        } as CSSProperties
      }
    >
      <p>
        {look} · {scheme} · web renderer
      </p>
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(3, minmax(0, 1fr))",
          gap: "var(--ds-space-6)",
          alignItems: "start",
        }}
      >
        <section>
          <p>Popover</p>
          <div className="ui-popup ui-glass" style={surface}>
            <strong>Workspace</strong>
            <p>Appearance and organization</p>
            <button type="button" className="ui-button">
              Choose icon
            </button>
          </div>
        </section>
        <section>
          <p>Menu</p>
          <div className="ui-popup ui-menu ui-glass" style={surface}>
            {["New workspace", "Rename", "Move to group"].map((label) => (
              <div className="ui-menu-item" key={label}>
                {label}
              </div>
            ))}
          </div>
        </section>
        <section>
          <p>Tooltip</p>
          <div
            className="ui-tooltip ui-glass"
            style={
              {
                ...surface,
                width: "fit-content",
                "--tooltip-blur": before
                  ? "var(--ds-glass-chip-blur)"
                  : "blur(var(--ds-transient-web-blur)) saturate(var(--ds-transient-web-saturation))",
                "--glass-backdrop": before
                  ? "var(--ds-glass-popover-blur)"
                  : "blur(var(--ds-transient-web-blur)) saturate(var(--ds-transient-web-saturation))",
                "--glass-tint": "var(--tooltip-tint)",
              } as CSSProperties
            }
          >
            Show sidebar <span>⌘S</span>
          </div>
        </section>
        <section>
          <p>Palette material sample</p>
          <div className="ui-popup ui-glass" style={surface}>
            <input className="ui-field" aria-label="Search commands" defaultValue="Workspace" />
            <div className="ui-menu-item">New workspace</div>
            <div className="ui-menu-item">Rename workspace</div>
          </div>
        </section>
        <section>
          <p>Toast</p>
          <Notice kind="toast" placement="stack" message="Workspace moved" actions={[{ id: "undo", label: "Undo" }]} />
        </section>
        <section>
          <p>Sheet</p>
          <div className="ui-dialog ui-glass" style={sheet}>
            <strong>Rename workspace</strong>
            <p>The name appears in the sidebar.</p>
            <input className="ui-field" aria-label="Workspace name" defaultValue="Workspace" />
            <p>
              <button type="button" className="ui-button">
                Cancel
              </button>{" "}
              <button type="button" className="ui-button">
                Save
              </button>
            </p>
          </div>
        </section>
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.transient-material",
  title: "Non-chat transient material",
  area: "Pages",
  height: 540,
  covers: ["pages/shared/transientMaterial.css", "ui/Notice.tsx", "ui/Tooltip.tsx"],
  load: async () => TransientMaterialGallery,
  variants: Object.fromEntries(
    (["light", "dark"] as const).flatMap((scheme) =>
      (["before", "standard", "quieter", "denser"] as const).map((look) => [
        `${look}-${scheme}`,
        {
          props: { look, scheme },
          note:
            look === "standard"
              ? "Picked: shared theme veil and menu frost; native palette/menu evidence is captured separately."
              : `${look} comparison of each web material; no change to layout or motion.`,
        },
      ]),
    ),
  ),
});
