// l10n-allow-file: sample artwork for the dev loop and the gallery (public-safe, never shipped data).
// Icons and screenshots drawn as SVG data URLs, so the mock catalog's listings look like real apps:
// an icon tile with a mark, and a window of the app in use (rows, cards, a chart, a sidebar).

const svg = (width: number, height: number, body: string) =>
  "data:image/svg+xml;utf8," +
  encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}" width="${width}" height="${height}" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif">${body}</svg>`,
  );

const escape = (text: string) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** Marks drawn white on an icon tile, in a 24-unit box (strokes). */
const MARKS: Record<string, string> = {
  cloud: '<path d="M7 18h10.5a4 4 0 0 0 .4-8 6 6 0 0 0-11.5 1.5A3.3 3.3 0 0 0 7 18z"/>',
  router:
    '<circle cx="5" cy="12" r="2.2"/><circle cx="19" cy="5" r="2.2"/><circle cx="19" cy="12" r="2.2"/><circle cx="19" cy="19" r="2.2"/><path d="M7.2 12h9.6M7 11c3-4 6-6 9.8-6M7 13c3 4 6 6 9.8 6"/>',
  clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6l1.4 1.4M17 17l1.4 1.4M5.6 18.4 7 17M17 7l1.4-1.4"/>',
  pr: '<circle cx="6" cy="6" r="2.2"/><circle cx="6" cy="18" r="2.2"/><circle cx="18" cy="18" r="2.2"/><path d="M6 8.2v7.6M18 15.8V10a3 3 0 0 0-3-3h-4m2-2-2 2 2 2"/>',
  note: '<path d="M6 4h9l3 3v13H6z"/><path d="M9 10h6M9 14h6M9 18h3"/>',
  pulse: '<path d="M3 12h4l2-5 4 10 2-5h6"/>',
  gauge: '<path d="M4 16a8 8 0 1 1 16 0"/><path d="M12 16l4-5"/>',
  radar: '<circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="4.5"/><path d="M12 12l6-6"/>',
  timer: '<circle cx="12" cy="13" r="7.5"/><path d="M12 9v4l2.5 1.5M10 3h4"/>',
  plug: '<path d="M9 3v5M15 3v5M7 8h10v3a5 5 0 0 1-10 0zM12 16v5"/>',
  paw: '<circle cx="7" cy="10" r="1.8"/><circle cx="17" cy="10" r="1.8"/><circle cx="10" cy="6" r="1.8"/><circle cx="14" cy="6" r="1.8"/><path d="M8 17c0-3 2-5 4-5s4 2 4 5-2 3-4 3-4 0-4-3z"/>',
  list: '<path d="M9 6h11M9 12h11M9 18h11M4.5 6h.5M4.5 12h.5M4.5 18h.5"/>',
};

/** An app icon: a rounded tile in `from`→`to` with a white mark. */
export function iconArt(mark: string, from: string, to: string): string {
  return svg(
    128,
    128,
    `<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${from}"/><stop offset="1" stop-color="${to}"/></linearGradient></defs>` +
      `<rect width="128" height="128" rx="28" fill="url(#g)"/>` +
      `<g transform="translate(28 28) scale(3)" fill="none" stroke="#fff" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${MARKS[mark] ?? MARKS.list}</g>`,
  );
}

export interface ShotRow {
  title: string;
  detail?: string;
  /** A status pill on the row's right. */
  status?: string;
  /** Green, amber, red or grey dot before the status. */
  tone?: "ok" | "warn" | "bad" | "idle";
}

const TONES = { ok: "#34c759", warn: "#ffb020", bad: "#ff5f57", idle: "#8e8e93" };

/**
 * A screenshot of an app in use: a dark window with a title bar, a sidebar of places and the app's
 * own content (`rows`, a `chart` of bars, or `cards` of numbers), tinted with the app's `accent`.
 */
export function screenshotArt({
  title,
  subtitle,
  accent,
  rows = [],
  chart,
  cards,
  sidebar = ["Home", "Workspaces", "Agents", "Apps"],
}: {
  title: string;
  subtitle?: string;
  accent: string;
  rows?: ShotRow[];
  chart?: number[];
  cards?: { label: string; value: string }[];
  sidebar?: string[];
}): string {
  const W = 1280;
  const H = 800;
  let body = `<rect width="${W}" height="${H}" fill="#1c1c1e"/>`;
  body += `<rect width="${W}" height="44" fill="#242426"/>`;
  body += ["#ff5f57", "#febc2e", "#28c840"]
    .map((c, i) => `<circle cx="${24 + i * 20}" cy="22" r="6" fill="${c}"/>`)
    .join("");
  body += `<rect x="0" y="44" width="220" height="${H - 44}" fill="#202022"/>`;
  sidebar.forEach((item, i) => {
    const y = 84 + i * 36;
    if (i === sidebar.length - 1)
      body += `<rect x="12" y="${y - 22}" width="196" height="32" rx="7" fill="${accent}" fill-opacity="0.22"/>`;
    body += `<rect x="26" y="${y - 12}" width="12" height="12" rx="3" fill="#8e8e93" fill-opacity="0.6"/>`;
    body += `<text x="48" y="${y - 1}" font-size="15" fill="#e5e5ea">${escape(item)}</text>`;
  });
  const x0 = 252;
  body += `<text x="${x0}" y="96" font-size="26" font-weight="700" fill="#f2f2f7">${escape(title)}</text>`;
  if (subtitle) body += `<text x="${x0}" y="124" font-size="15" fill="#8e8e93">${escape(subtitle)}</text>`;
  let y = 156;
  if (cards?.length) {
    const width = (W - x0 - 32 - (cards.length - 1) * 16) / cards.length;
    cards.forEach((card, i) => {
      const x = x0 + i * (width + 16);
      body += `<rect x="${x}" y="${y}" width="${width}" height="112" rx="12" fill="#2c2c2e"/>`;
      body += `<text x="${x + 20}" y="${y + 34}" font-size="14" fill="#8e8e93">${escape(card.label)}</text>`;
      body += `<text x="${x + 20}" y="${y + 80}" font-size="34" font-weight="700" fill="#f2f2f7">${escape(card.value)}</text>`;
      body += `<rect x="${x + 20}" y="${y + 94}" width="${width - 40}" height="5" rx="2.5" fill="#3a3a3c"/>`;
      body += `<rect x="${x + 20}" y="${y + 94}" width="${(width - 40) * (0.3 + 0.2 * i)}" height="5" rx="2.5" fill="${accent}"/>`;
    });
    y += 140;
  }
  if (chart?.length) {
    const height = 200;
    body += `<rect x="${x0}" y="${y}" width="${W - x0 - 32}" height="${height + 40}" rx="12" fill="#2c2c2e"/>`;
    const max = Math.max(...chart);
    const step = (W - x0 - 72) / chart.length;
    chart.forEach((value, i) => {
      const h = (value / max) * (height - 20);
      body += `<rect x="${x0 + 20 + i * step}" y="${y + 20 + height - h}" width="${step * 0.62}" height="${h}" rx="4" fill="${accent}" fill-opacity="${0.55 + (0.45 * i) / chart.length}"/>`;
    });
    y += height + 68;
  }
  rows.forEach((row, i) => {
    const top = y + i * 64;
    if (top + 56 > H) return;
    body += `<rect x="${x0}" y="${top}" width="${W - x0 - 32}" height="56" rx="10" fill="#2c2c2e" fill-opacity="${i % 2 ? 0.6 : 1}"/>`;
    body += `<rect x="${x0 + 16}" y="${top + 14}" width="28" height="28" rx="7" fill="${accent}" fill-opacity="0.85"/>`;
    body += `<text x="${x0 + 58}" y="${top + 26}" font-size="16" font-weight="600" fill="#f2f2f7">${escape(row.title)}</text>`;
    if (row.detail)
      body += `<text x="${x0 + 58}" y="${top + 45}" font-size="13" fill="#8e8e93">${escape(row.detail)}</text>`;
    if (row.status) {
      const color = TONES[row.tone ?? "idle"];
      const w = 26 + row.status.length * 8;
      const x = W - 48 - w;
      body += `<rect x="${x}" y="${top + 15}" width="${w}" height="26" rx="13" fill="${color}" fill-opacity="0.16"/>`;
      body += `<circle cx="${x + 13}" cy="${top + 28}" r="4" fill="${color}"/>`;
      body += `<text x="${x + 23}" y="${top + 33}" font-size="13" fill="${color}">${escape(row.status)}</text>`;
    }
  });
  return svg(W, H, body);
}
