// l10n-allow-file: gallery and test fixtures (a sample page's text), not shipped UI.
// A turn's before and after picture of a local page, as acpmux would keep them
// (hub/turn_shots.rs): a pricing page whose turn restyled the cards and the call to action.
// SVG data URLs, so the gallery and the tests need no binary files.

const page = (body: string) =>
  `data:image/svg+xml;charset=utf-8,${encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="400" viewBox="0 0 640 400" font-family="Helvetica, Arial, sans-serif">${body}</svg>`,
  )}`;

const card = (x: number, title: string, price: string, fill: string, ink: string, button: string, label: string) =>
  `<rect x="${x}" y="120" width="180" height="220" rx="10" fill="${fill}" stroke="#d7dbe0"/>` +
  `<text x="${x + 20}" y="156" font-size="16" fill="${ink}">${title}</text>` +
  `<text x="${x + 20}" y="200" font-size="30" font-weight="700" fill="${ink}">${price}</text>` +
  `<rect x="${x + 20}" y="280" width="140" height="36" rx="8" fill="${button}"/>` +
  `<text x="${x + 90}" y="303" font-size="14" text-anchor="middle" fill="#fff">${label}</text>`;

export const PAGE_BEFORE = page(
  `<rect width="640" height="400" fill="#ffffff"/>` +
    `<rect width="640" height="56" fill="#f3f4f6"/>` +
    `<text x="24" y="35" font-size="18" fill="#111827">Acme</text>` +
    `<text x="24" y="96" font-size="22" fill="#111827">Pricing</text>` +
    card(24, "Starter", "$0", "#ffffff", "#111827", "#2563eb", "Sign up") +
    card(230, "Team", "$12", "#ffffff", "#111827", "#2563eb", "Sign up") +
    card(436, "Scale", "$40", "#ffffff", "#111827", "#2563eb", "Sign up"),
);

export const PAGE_AFTER = page(
  `<rect width="640" height="400" fill="#0b1020"/>` +
    `<rect width="640" height="56" fill="#121a33"/>` +
    `<text x="24" y="35" font-size="18" fill="#e5e7eb">Acme</text>` +
    `<text x="24" y="96" font-size="22" font-weight="700" fill="#e5e7eb">Pick a plan</text>` +
    card(24, "Starter", "$0", "#141c38", "#e5e7eb", "#334155", "Start free") +
    card(230, "Team", "$12", "#1e2a55", "#ffffff", "#16a34a", "Start trial") +
    card(436, "Scale", "$40", "#141c38", "#e5e7eb", "#334155", "Talk to us"),
);
