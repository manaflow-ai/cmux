// l10n-allow-file: gallery fixtures (sample chat colours), not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { ChatColorsPanel, type ChatColorsLook } from "./ChatColorsPanel";
import type { ChatColorRole, ChatColorsState } from "./host";

type Colors = Partial<Record<ChatColorRole, string | null>>;

interface FixtureProps {
  look: ChatColorsLook;
  /** The chat's page colour and default bubbles: a dark or a light theme. */
  dark: boolean;
  colors: Colors;
}

/** Black or white, whichever reads on `fill` (the host's Automatic, roughly). */
function readable(fill: string): string {
  const value = Number.parseInt(fill.slice(1, 7), 16);
  const luminance = 0.2126 * ((value >> 16) & 255) + 0.7152 * ((value >> 8) & 255) + 0.0722 * (value & 255);
  return luminance > 150 ? "#000000" : "#FFFFFF";
}

/** The state the host would stream for `colors`: the iMessage style's defaults under the choice. */
function resolve(colors: Colors, dark: boolean): ChatColorsState {
  const sent = colors.sent ?? "#0284FE";
  const received = colors.received ?? (dark ? "#3B3B3D" : "#E9E9EB");
  return {
    session: "gallery",
    colors,
    preview: {
      background: dark ? "#1E1E1E" : "#FFFFFF",
      sent: { fill: sent, text: colors.sentText ?? readable(sent) },
      received: { fill: received, text: colors.receivedText ?? readable(received) },
    },
  };
}

const strings = createStrings(table, ["en"]);

/** The panel with a local store in place of the host: a pick redraws as the host's state would. */
function ChatColorsFixture({ look, dark, colors: initial }: FixtureProps) {
  const [colors, setColors] = useState<Colors>(initial);
  return (
    <div style={{ width: 340, height: 340 }}>
      <ChatColorsPanel
        strings={strings}
        look={look}
        state={resolve(colors, dark)}
        onPick={(role, color) => setColors((now) => ({ ...now, [role]: color }))}
        onCustom={() => undefined}
        onReset={() => setColors({})}
        onDone={() => undefined}
      />
    </div>
  );
}

const custom: Colors = { sent: "#34C759", sentText: "#000000", received: "#1C2A4A", receivedText: "#FFFFFF" };

export default componentEntry<FixtureProps>({
  id: "home.chat-colors",
  title: "Chat Colors",
  area: "Home and Chief",
  height: 340,
  widths: { narrow: 340, normal: 340, wide: 340 },
  covers: ["page:cmux.home-chat-colors", "pages/home-chat-colors/ChatColorsPanel.tsx#ChatColorsPanel"],
  load: async () => ChatColorsFixture,
  styles: () => import("./styles.css"),
  variants: {
    default: {
      note: "Picked layout (rows): a chat with no colours of its own; Default and Automatic selected, Reset off.",
      props: { look: "rows", dark: false, colors: {} },
    },
    "custom-both": {
      note: "Custom colours on both sides, Reset on.",
      props: { look: "rows", dark: false, colors: custom },
    },
    "text-only": {
      note: "A chat with only text colours: the bubbles keep the style's fills.",
      props: { look: "rows", dark: false, colors: { sentText: "#000000", receivedText: "#000000" } },
    },
    dark: {
      note: "The preview on a dark theme's page colour.",
      props: { look: "rows", dark: true, colors: { sent: "#AF52DE" } },
    },
    light: {
      note: "The preview on a light theme's page colour.",
      props: { look: "rows", dark: false, colors: { received: "#D9F7E0" } },
    },
    "caption-labels": {
      note: "Alternative look: smaller row labels, wider swatch spacing.",
      props: { look: "caption-labels", dark: false, colors: custom },
    },
    grouped: {
      note: "Alternative look: each side in a quiet grouped box.",
      props: { look: "grouped", dark: false, colors: custom },
    },
  },
});
