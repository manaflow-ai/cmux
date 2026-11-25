// l10n-allow-file: gallery fixtures, not shipped UI.
import React from "react";
import { componentEntry } from "../../gallery/format";
import { setExperimentSwitches } from "../../experiments/switches";

type Props = { on?: boolean; menu?: boolean };

// The groups the app's Customizations menu lists (SettingsSchema.quickToggleGroups), drawn here as a
// stand-in: the real menu is a native NSMenu, which the gallery cannot draw.
const MENU: { group: string; rows: { label: string; on?: boolean }[] }[] = [
  {
    group: "Experiments",
    rows: [
      { label: "Customize Button Under the Composer", on: true },
      { label: "Agent Badges" },
      { label: "Hover Look" },
    ],
  },
  { group: "Labs", rows: [{ label: "Glass Toolbar Groups" }, { label: "Extension Chat Widgets", on: true }] },
];

export default componentEntry<Props>({
  id: "agent-pane.composer-customizer",
  title: "Customize button under the composer",
  area: "Agent pane",
  height: 360,
  widths: { normal: 720, narrow: 420 },
  covers: ["agent-session/acpmux/ComposerCustomizer.tsx#ComposerCustomizer"],
  styles: () =>
    Promise.all([import("./styles.css"), import("./composerLocation.css"), import("./composerCustomizer.css")]),
  load: () =>
    import("./ComposerCustomizer").then(
      ({ ComposerCustomizer }) =>
        function Stage({ on = true, menu = false }: Props) {
          setExperimentSwitches(on ? { composerCustomizer: true } : {});
          return (
            <div
              style={{
                padding: menu
                  ? "var(--ds-space-5)"
                  : "calc(var(--ds-space-5) * 7.5) var(--ds-space-5) var(--ds-space-5)",
              }}
            >
              <form
                className="acpmux-composer"
                style={{ position: "relative" }}
                onSubmit={(event) => event.preventDefault()}
              >
                <div
                  className="acpmux-composer-box"
                  style={{
                    minHeight: 64,
                    borderRadius: "var(--ds-radius-card)",
                    border: "1px solid color-mix(in srgb, currentColor 18%, transparent)",
                    padding: "var(--ds-space-3)",
                  }}
                >
                  <span style={{ opacity: 0.5 }}>Ask anything</span>
                </div>
                <div className="acpmux-chrome-area">
                  <div className="acpmux-composer-bar acpmux-composer-foot" data-footer-look="plain">
                    <span style={{ opacity: 0.7 }}>Ask before edits</span>
                    <span style={{ flex: 1 }} />
                    <span style={{ opacity: 0.7 }}>Opus 5.5 Medium</span>
                    <ComposerCustomizer />
                  </div>
                </div>
                {menu && (
                  <div
                    role="menu"
                    data-gallery-native-menu=""
                    style={{
                      position: "absolute",
                      left: "50%",
                      top: "100%",
                      marginTop: "var(--grid-half-step)",
                      transform: "translateX(-50%)",
                      minWidth: 280,
                      padding: "var(--cmux-menu-highlight-inset)",
                      borderRadius: "var(--ds-radius-popup)",
                      background: "Canvas",
                      boxShadow: "var(--ui-popup-shadow)",
                      fontSize: "var(--text-body)",
                    }}
                  >
                    {MENU.map(({ group, rows }) => (
                      <div key={group}>
                        <div
                          style={{
                            padding: "var(--ds-space-1) var(--cmux-menu-state-x)",
                            opacity: 0.55,
                            fontSize: "var(--text-caption)",
                            fontWeight: 600,
                          }}
                        >
                          {group}
                        </div>
                        {rows.map((row) => (
                          <div
                            key={row.label}
                            role="menuitemcheckbox"
                            aria-checked={row.on === true}
                            style={{ padding: "var(--grid-half-step) var(--cmux-menu-state-x)" }}
                          >
                            <span style={{ display: "inline-block", width: "var(--ds-icon-16)" }}>
                              {row.on ? "✓" : ""}
                            </span>
                            {row.label}
                          </div>
                        ))}
                      </div>
                    ))}
                    <div
                      style={{
                        borderTop: "1px solid color-mix(in srgb, currentColor 15%, transparent)",
                        margin: "var(--ds-space-1) 0",
                      }}
                    />
                    <div
                      role="menuitem"
                      style={{
                        padding:
                          "var(--grid-half-step) var(--cmux-menu-state-x) var(--grid-half-step) calc(var(--cmux-menu-state-x) + var(--ds-icon-16))",
                      }}
                    >
                      All Customizations…
                    </div>
                  </div>
                )}
              </form>
            </div>
          );
        },
    ),
  // Off is the default (Settings > Advanced > Experiments): the row as it is today. On, the button
  // waits until the pointer is over the composer, then shows centered under the box; a click pops
  // the app's Customizations menu below the button (drawn here as a stand-in, `menu`).
  variants: {
    off: { props: { on: false } },
    resting: { props: {} },
    hover: {
      props: {},
      play: async (ctx) => {
        await ctx.hover({ selector: ".acpmux-composer-box" });
      },
    },
    menu: {
      props: { menu: true },
      play: async (ctx) => {
        await ctx.hover({ selector: ".acpmux-composer-box" });
      },
    },
  },
});
