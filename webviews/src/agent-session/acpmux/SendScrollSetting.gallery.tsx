// l10n-allow-file: gallery fixture copy, not shipped UI.
import { useEffect } from "react";
import { componentEntry } from "../../gallery/format";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { Switch } from "../../pages/settings/editors/ToggleEditor";
import { setComposerSettings, setScrollToBottomOnSend, useComposerSettings } from "./composerSettings";
import { shouldScrollToBottomAfterSend } from "./sendScrollSetting";
import "../../pages/settings/styles.css";

type Props = { placement: "settings" | "composer" | "both"; initial: boolean };

function SettingRow({ checked }: { checked: boolean }) {
  const menu: ContextMenuItem[] = [
    {
      id: "scrollToBottomOnSend",
      label: "Scroll to bottom when I send",
      checked,
      onSelect: () => setScrollToBottomOnSend(!checked),
    },
  ];
  return (
    <div
      data-setting-row
      style={{ display: "flex", alignItems: "center", gap: 12, padding: "12px 14px", borderRadius: 12 }}
    >
      <div style={{ flex: 1 }}>
        <ContextMenu items={menu} className="settings-row">
          <span>
            <strong id="send-scroll-setting-label" style={{ display: "block", fontWeight: 500 }}>
              Scroll to bottom when I send
            </strong>
            <small style={{ color: "var(--agent-muted)" }}>Keep today’s send-to-latest behavior.</small>
          </span>
        </ContextMenu>
      </div>
      <Switch
        checked={checked}
        disabled={false}
        labelId="send-scroll-setting-label"
        onToggle={setScrollToBottomOnSend}
      />
    </div>
  );
}

function ComposerHint({ checked }: { checked: boolean }) {
  const follows = shouldScrollToBottomAfterSend(checked, false);
  const menu: ContextMenuItem[] = [
    {
      id: "scrollToBottomOnSend",
      label: "Scroll to bottom when I send",
      checked,
      onSelect: () => setScrollToBottomOnSend(!checked),
    },
  ];
  return (
    <div
      data-composer-placement
      style={{
        display: "flex",
        alignItems: "center",
        gap: 10,
        padding: "10px 12px",
        borderRadius: 14,
        background: "color-mix(in srgb, var(--agent-text) 5%, transparent)",
      }}
    >
      <div style={{ flex: 1 }}>
        <ContextMenu items={menu} className="acpmux-composer-box">
          <span style={{ display: "block" }}>
            <span id="send-scroll-composer-label" style={{ display: "block", fontSize: 13 }}>
              Composer send behavior
            </span>
            <small style={{ color: "var(--agent-muted)" }}>
              {follows ? "Sending follows the latest row." : "Sending preserves your place."}
            </small>
          </span>
        </ContextMenu>
      </div>
      <Switch
        checked={checked}
        disabled={false}
        labelId="send-scroll-composer-label"
        onToggle={setScrollToBottomOnSend}
      />
    </div>
  );
}

function SendScrollSettingFixture({ placement, initial }: Props) {
  const { scrollToBottomOnSend: checked } = useComposerSettings();
  useEffect(() => setComposerSettings({ scrollToBottomOnSend: initial }), [initial]);
  const showSettings = placement === "settings" || placement === "both";
  const showComposer = placement === "composer" || placement === "both";
  return (
    <section
      data-send-scroll-gallery={placement}
      style={{
        display: "grid",
        gap: 12,
        padding: 16,
        color: "var(--agent-text)",
        background: "var(--agent-bg)",
        fontFamily: "system-ui, sans-serif",
      }}
    >
      {showSettings ? <SettingRow checked={checked} /> : null}
      {showComposer ? <ComposerHint checked={checked} /> : null}
    </section>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.send-scroll-setting",
  title: "Scroll to bottom when I send",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: "[data-send-scroll-gallery]" }],
  covers: [
    "agent-session/acpmux/composerSettings.ts#scrollToBottomOnSend",
    "agent-session/acpmux/sendScrollSetting.ts",
  ],
  variants: {
    "settings-on": {
      note: "Settings > Agent chat: on by default, preserving the existing jump to the latest message.",
      props: { placement: "settings", initial: true },
    },
    "composer-off": {
      note: "Composer context: off keeps an up-scrolled reader in place while the sent prompt arrives below.",
      props: { placement: "composer", initial: false },
    },
    "settings-and-composer": {
      note: "Settings and composer show one shared persisted choice, so the setting is discoverable in both places.",
      props: { placement: "both", initial: true },
    },
    "settings-off": {
      note: "Settings > Agent chat: off preserves the reader's place; a jump-latest affordance signals new content.",
      props: { placement: "settings", initial: false },
    },
  },
  load: async () => SendScrollSettingFixture,
});
