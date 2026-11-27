// l10n-allow-file: gallery mocks of menu layouts (sample labels), not shipped UI.
// The chat's display settings in its ··· menu (plans/cmux-next/chat-display-settings-DESIGN.md),
// three layouts side by side:
//   A (Recommended, shipped): a "Text & Width…" row opens a popover with every option, as the
//     Markdown viewer's Aa popover does. One place, every option, live preview.
//   B: a "Text" submenu of presets (Smaller/Default/Larger, Narrow/Default/Wide/Full, code fonts):
//     fast, but no exact sizes and no line height.
//   C: inline steppers inside the menu itself: quick for size, but the menu grows by five rows and
//     a menu closes on the first click elsewhere.
import { componentEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { ChatDisplayRows } from "./ChatDisplaySettings";

type Layout = "popover" | "submenu" | "inline";

const MENU = ["Rename", "Pin", "—", "Fork", "Copy as Markdown", "—", "Move Right", "New Workspace", "—"];

function MenuMock({ children }: { children?: React.ReactNode }) {
  return (
    <div
      className="text-body"
      style={{
        width: 240,
        padding: 6,
        borderRadius: 10,
        background: "var(--agent-surface-elevated, #2b2b2b)",
        color: "var(--agent-text, #eee)",
        boxShadow: "0 6px 24px rgb(0 0 0 / 0.25)",
      }}
    >
      {MENU.map((item, index) =>
        item === "—" ? (
          <div
            key={index}
            style={{ height: 1, margin: "4px 6px", background: "color-mix(in srgb, currentColor 12%, transparent)" }}
          />
        ) : (
          <div key={index} style={{ padding: "4px 8px", borderRadius: 6 }}>
            {item}
          </div>
        ),
      )}
      {children}
    </div>
  );
}

const highlighted = {
  padding: "4px 8px",
  borderRadius: 6,
  background: "color-mix(in srgb, currentColor 10%, transparent)",
  display: "flex",
  justifyContent: "space-between",
} as const;

const typeCustomFont = async (ctx: PlayContext) => {
  await ctx.type("JetBrains Mono", { selector: '.acpmux-display-row input[type="text"]' });
};

function Layouts({ layout }: { layout: Layout }) {
  if (layout === "popover")
    return (
      <div style={{ display: "flex", gap: 12, alignItems: "flex-start", padding: 16 }}>
        <MenuMock>
          <div style={highlighted}>
            <span>Text &amp; Width…</span>
          </div>
        </MenuMock>
        <div
          className="acpmux-display"
          style={{
            borderRadius: 10,
            background: "var(--agent-surface-elevated, #2b2b2b)",
            boxShadow: "0 6px 24px rgb(0 0 0 / 0.25)",
          }}
        >
          <ChatDisplayRows />
        </div>
      </div>
    );
  if (layout === "submenu")
    return (
      <div style={{ display: "flex", gap: 4, alignItems: "flex-end", padding: 16 }}>
        <MenuMock>
          <div style={highlighted}>
            <span>Text</span>
            <span>›</span>
          </div>
        </MenuMock>
        <MenuMock>
          {[
            "Smaller Text",
            "Default Size",
            "Larger Text",
            "—",
            "Narrow",
            "Default Width",
            "Wide",
            "Full Width",
            "—",
            "Code: Terminal Font",
            "Code: SF Mono",
            "Code: JetBrains Mono",
          ].map((item, index) =>
            item === "—" ? (
              <div
                key={index}
                style={{
                  height: 1,
                  margin: "4px 6px",
                  background: "color-mix(in srgb, currentColor 12%, transparent)",
                }}
              />
            ) : (
              <div key={index} style={{ padding: "4px 8px" }}>
                {item}
              </div>
            ),
          )}
        </MenuMock>
      </div>
    );
  return (
    <div style={{ padding: 16 }}>
      <MenuMock>
        {[
          ["Text Size", "14 pt"],
          ["Width", "800 pt"],
          ["Line Height", "1.63"],
          ["Code Size", "88%"],
        ].map(([label, value]) => (
          <div key={label} style={{ display: "flex", alignItems: "center", gap: 6, padding: "4px 8px" }}>
            <span style={{ flex: 1 }}>{label}</span>
            <span style={{ opacity: 0.7 }}>{value}</span>
            <span
              style={{
                padding: "0 6px",
                borderRadius: 5,
                background: "color-mix(in srgb, currentColor 10%, transparent)",
              }}
            >
              −
            </span>
            <span
              style={{
                padding: "0 6px",
                borderRadius: 5,
                background: "color-mix(in srgb, currentColor 10%, transparent)",
              }}
            >
              +
            </span>
          </div>
        ))}
      </MenuMock>
    </div>
  );
}

export default componentEntry<{ layout: Layout }>({
  id: "agent-pane.chat-display-menu",
  title: "Chat display settings in the ··· menu",
  area: "Agent pane",
  height: 520,
  covers: [
    "agent-session/acpmux/ChatDisplaySettings.tsx#ChatDisplaySettings",
    "agent-session/acpmux/ChatDisplaySettings.tsx#ChatDisplayRows",
  ],
  pane: true,
  load: () => Promise.resolve(Layouts),
  variants: {
    "a-popover-recommended": {
      props: { layout: "popover" },
      note: "Recommended, shipped: Text & Width… opens a popover with every option, like the Markdown viewer's Aa popover",
    },
    "b-preset-submenu": {
      props: { layout: "submenu" },
      note: "A Text submenu of presets: fast, but no exact sizes or line height",
    },
    "c-inline-steppers": {
      props: { layout: "inline" },
      note: "Steppers inside the menu: quick, but the menu grows and closes on the first click elsewhere",
    },
    "d-custom-font-typed": {
      props: { layout: "popover" },
      note: "A multi-word custom code font remains intact while it is typed in the Text & Width popover",
      play: typeCustomFont,
    },
  },
});
