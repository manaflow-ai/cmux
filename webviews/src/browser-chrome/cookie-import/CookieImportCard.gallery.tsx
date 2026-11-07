// l10n-allow-file: gallery fixtures (sample lines the host localizes in the app), not shipped UI.
// The Import Cookies card in its three looks, over a sample page bottom. The app draws `split`
// (design/browser-chrome.md, "Import Cookies card"). The stage shows the last answer instead of
// closing, so every button can be clicked through.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { CookieImportCard } from "./CookieImportCard";
import type { CookieImportCardModel, CookieImportChoice, CookieImportLook } from "./model";

type Props = { model: CookieImportCardModel; look?: CookieImportLook; width?: number };

// A neutral round app icon (the host sends the browser's own app icon).
const ICON = `data:image/svg+xml,${encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5b8def"/><stop offset="1" stop-color="#3a5bc7"/></linearGradient></defs><circle cx="32" cy="32" r="28" fill="url(#g)"/><circle cx="32" cy="32" r="11" fill="#fff"/><circle cx="32" cy="32" r="7" fill="#3a5bc7"/></svg>',
)}`;

const chrome: CookieImportCardModel = {
  title: "Import cookies from Google Chrome",
  detail: "Stay signed in to your sites. Nothing leaves this Mac.",
  importTitle: "Import…",
  notNowTitle: "Not Now",
  neverTitle: "Don't Show Again",
  icon: ICON,
};

function CookieImportFixture({ model, look, width = 460 }: Props) {
  const [answer, setAnswer] = useState<CookieImportChoice | null>(null);
  return (
    <div style={{ padding: 16, display: "flex", flexDirection: "column", gap: 8 }}>
      <div style={{ width, maxWidth: "100%" }}>
        <CookieImportCard model={model} look={look} onChoice={setAnswer} />
      </div>
      <span style={{ font: "var(--text-caption) var(--font-ui)", color: "var(--ds-color-faint)" }}>
        {answer ? `Answered: ${answer}` : " "}
      </span>
    </div>
  );
}

export default componentEntry<Props>({
  id: "browser-chrome.cookie-import",
  title: "Import Cookies card",
  area: "Browser chrome",
  height: 200,
  widths: { narrow: 360, normal: 520, wide: 640 },
  covers: ["browser-chrome/cookie-import/CookieImportCard.tsx"],
  keywords: ["import cookies", "banner", "chrome", "sign in", "don't show again", "not now"],
  load: async () => CookieImportFixture,
  options: [
    {
      id: "look",
      label: "Look",
      kind: "choice",
      choices: [
        { value: "split", label: "Split (picked)" },
        { value: "trailing", label: "Trailing" },
        { value: "inline", label: "Inline" },
      ],
      defaultValue: "split",
    },
  ],
  variants: {
    split: {
      props: { model: chrome, look: "split" },
      note: "Picked. Don't Show Again on the title's column, Not Now and Import matched at the end.",
    },
    trailing: {
      props: { model: chrome, look: "trailing" },
      note: "All three answers grouped at the end; the link reads as a third button.",
    },
    inline: {
      props: { model: chrome, look: "inline", width: 620 },
      note: "One row for wide panes; in a narrow pane the buttons squeeze the text.",
    },
    "split-narrow": {
      props: { model: chrome, look: "split", width: 320 },
      note: "A narrow pane: the detail wraps to two lines, the row keeps its alignment.",
    },
    "split-no-never": {
      props: { model: { ...chrome, neverTitle: null }, look: "split" },
      note: "No Don't Show Again: only the two buttons, at the end.",
    },
    "split-no-icon": {
      props: { model: { ...chrome, icon: null }, look: "split" },
    },
    "split-long-labels": {
      props: {
        model: {
          ...chrome,
          title: "Cookies aus Google Chrome importieren",
          detail: "Bleiben Sie bei Ihren Websites angemeldet. Nichts verlässt diesen Mac.",
          importTitle: "Importieren …",
          notNowTitle: "Jetzt nicht",
          neverTitle: "Nicht mehr anzeigen",
        },
        look: "split",
      },
      note: "Longer labels: the two buttons stay one width.",
    },
    "split-narrow-long-labels": {
      props: {
        model: {
          ...chrome,
          title: "Cookies aus Google Chrome importieren",
          detail: "Bleiben Sie bei Ihren Websites angemeldet. Nichts verlässt diesen Mac.",
          importTitle: "Importieren …",
          notNowTitle: "Jetzt nicht",
          neverTitle: "Nicht mehr anzeigen",
        },
        look: "split",
        width: 300,
      },
      note: "Longer labels in a narrow pane: the buttons go to their own line at the end, inside the card.",
    },
  },
});
