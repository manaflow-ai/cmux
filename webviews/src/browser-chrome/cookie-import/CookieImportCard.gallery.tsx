// l10n-allow-file: gallery fixtures (sample lines the host localizes in the app), not shipped UI.
// The Import Cookies card in its looks, on the toast glass over a sample page bottom. The app draws
// `toast` (design/browser-chrome.md, "Import Cookies card"). The stage shows the last answer instead
// of closing, so every button can be clicked through.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { CookieImportCard } from "./CookieImportCard";
import type { CookieImportCardModel, CookieImportCommand, CookieImportLook } from "./model";

type Props = { model: CookieImportCardModel; look?: CookieImportLook; width?: number };

// A neutral round app icon (the host sends the browser's own app icon).
const ICON = `data:image/svg+xml,${encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5b8def"/><stop offset="1" stop-color="#3a5bc7"/></linearGradient></defs><circle cx="32" cy="32" r="28" fill="url(#g)"/><circle cx="32" cy="32" r="11" fill="#fff"/><circle cx="32" cy="32" r="7" fill="#3a5bc7"/></svg>',
)}`;

const chrome: CookieImportCardModel = {
  title: "Import cookies from Google Chrome",
  importTitle: "Import…",
  notNowTitle: "Not Now",
  neverTitle: "Don't Show Again",
  icon: ICON,
};

// Lines of a page under the card, so the glass shows what it blurs.
const PAGE = Array.from(
  { length: 7 },
  (_, i) => ["Release notes", "Fixed the sign-in loop on the account page.", "Build 1842 · 3 files changed"][i % 3],
);

function CookieImportFixture({ model, look, width = 560 }: Props) {
  const [answer, setAnswer] = useState<CookieImportCommand | null>(null);
  return (
    <div data-ci-stage style={{ position: "relative", padding: 16, display: "flex", flexDirection: "column", gap: 8 }}>
      <div aria-hidden style={{ position: "absolute", inset: 0, padding: "4px 16px", overflow: "hidden" }}>
        {PAGE.map((line, i) => (
          <div
            key={i}
            style={{
              font: "var(--weight-emphasis) var(--text-title)/var(--text-title--line-height) var(--font-ui)",
              color: i % 3 === 1 ? "var(--ds-color-accent)" : "var(--ds-color-fg)",
            }}
          >
            {line}
          </div>
        ))}
      </div>
      <div style={{ position: "relative", width, maxWidth: "100%" }}>
        <CookieImportCard model={model} look={look} onChoice={setAnswer} />
      </div>
      <span
        style={{ position: "relative", font: "var(--text-caption) var(--font-ui)", color: "var(--ds-color-faint)" }}
      >
        {answer ? `Answered: ${JSON.stringify(answer)}` : " "}
      </span>
    </div>
  );
}

export default componentEntry<Props>({
  id: "browser-chrome.cookie-import",
  title: "Import Cookies card",
  area: "Browser chrome",
  height: 160,
  widths: { narrow: 360, normal: 520, wide: 640 },
  covers: ["browser-chrome/cookie-import/CookieImportCard.tsx"],
  keywords: ["import cookies", "toast", "chrome", "sign in", "don't show again", "not now"],
  load: async () => CookieImportFixture,
  options: [
    {
      id: "look",
      label: "Look",
      kind: "choice",
      choices: [
        { value: "toast", label: "Toast (picked)" },
        { value: "buttons", label: "Buttons" },
        { value: "stacked", label: "Stacked" },
      ],
      defaultValue: "toast",
    },
  ],
  variants: {
    toast: {
      props: { model: chrome, look: "toast" },
      note: "Picked. The dialog card's grammar: the line in the title weight, Don't Show Again quiet, Not Now, Import primary.",
    },
    buttons: {
      props: { model: chrome, look: "buttons", width: 640 },
      note: "One row of buttons; wider than a toast, and the three answers outweigh the line.",
    },
    stacked: {
      props: { model: chrome, look: "stacked" },
      note: "The previous two-row layout without its detail and checkbox: still a card, not a toast.",
    },
    "toast-narrow": {
      props: { model: chrome, look: "toast", width: 320 },
      note: "A narrow pane: the answers wrap under the line, at the trailing edge.",
    },
    "toast-min": {
      props: { model: chrome, look: "toast", width: 184 },
      note: "The narrowest pane (200 pt less the insets): every answer stays inside the card.",
    },
    "toast-min-long-labels": {
      props: {
        model: {
          ...chrome,
          title: "Cookies aus Google Chrome importieren",
          importTitle: "Importieren …",
          notNowTitle: "Jetzt nicht",
          neverTitle: "Nicht mehr anzeigen",
        },
        look: "toast",
        width: 184,
      },
      note: "The narrowest pane with longer labels: a label too long ends in an ellipsis inside the card.",
    },
    "toast-no-never": {
      props: { model: { ...chrome, neverTitle: null }, look: "toast" },
      note: "No Don't Show Again: Import and the close button.",
    },
    "toast-no-icon": {
      props: { model: { ...chrome, icon: null }, look: "toast" },
    },
    "toast-long-labels": {
      props: {
        model: {
          ...chrome,
          title: "Cookies aus Google Chrome importieren",
          importTitle: "Importieren …",
          notNowTitle: "Jetzt nicht",
          neverTitle: "Nicht mehr anzeigen",
        },
        look: "toast",
      },
      note: "Longer labels: the line wraps before the answers leave the row.",
    },
  },
});
