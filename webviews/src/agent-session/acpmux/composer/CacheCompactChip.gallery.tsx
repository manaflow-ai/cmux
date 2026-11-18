// l10n-allow-file: gallery labels, not shipped UI.
// The composer's cache chip beside Send (CacheCompactChip.tsx; Leo's ask: once a big Claude chat's
// prompt cache has expired, Compact with the token count beside Send; Enter compacts first, then
// sends; a click flips it to Keep, which sends cold). The real chip and hook on a pinned clock, in
// the composer bar beside a Send button.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";

type Props = {
  /// The usage report's `compactOnReturn`.
  compactOnReturn?: boolean;
  /// The cache's time left (ms; 0 or less: expired), on the pinned clock.
  cacheLeftMs: number;
  /// A turn runs.
  running?: boolean;
  /// The composer holds text.
  hasText?: boolean;
};

const GALLERY_NOW = Date.UTC(2026, 10, 18, 9, 30);
const galleryNow = () => GALLERY_NOW;

const chipReads =
  (expected: string | null): Play =>
  async (ctx) => {
    const chip = () => ctx.document.querySelector<HTMLElement>(".acpmux-cache-compact");
    if (expected === null) {
      if (chip()) throw new Error(`The cache chip shows "${chip()!.textContent}"; it should be hidden`);
      return;
    }
    await ctx.waitFor(() => chip() !== null);
    if (chip()!.textContent !== expected)
      throw new Error(`The cache chip reads "${chip()!.textContent}", not "${expected}"`);
  };

const flipToKeep: Play = async (ctx) => {
  await chipReads("Compact · 312K")(ctx);
  await ctx.click({ selector: ".acpmux-cache-compact" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cache-compact")?.textContent === "Keep");
};

export default componentEntry<Props>({
  id: "agent-pane.composer-cache-compact",
  title: "Composer cache chip (Compact or Keep)",
  area: "Composer",
  pane: true,
  height: 120,
  widths: { narrow: 360, normal: 560 },
  keywords: ["cache", "compact", "keep", "prompt cache", "send"],
  covers: ["agent-session/acpmux/composer/CacheCompactChip.tsx#CacheCompactChip"],
  styles: () =>
    Promise.all([import("../styles.css"), import("../composerControls.css"), import("../composerStates.css")]).then(
      () => undefined,
    ),
  load: () =>
    import("./CacheCompactChip").then(
      ({ CacheCompactChip, useCacheCompactChip }) =>
        function Gallery({ compactOnReturn = true, cacheLeftMs, running = false, hasText = true }: Props) {
          const control = useCacheCompactChip({
            usage: { used: 312_400, compactOnReturn, cacheExpiresAt: GALLERY_NOW + cacheLeftMs },
            idle: !running,
            hasText,
            now: galleryNow,
          });
          return (
            <div className="acpmux-shell" style={{ display: "block", height: "auto", padding: "var(--ds-space-4)" }}>
              <div className="acpmux-composer">
                <div className="acpmux-composer-bar" style={{ justifyContent: "flex-end" }}>
                  <CacheCompactChip control={control} />
                  <button type="button" className="acpmux-send acpmux-send-ready" aria-label="Send">
                    ↵
                  </button>
                </div>
              </div>
            </div>
          );
        },
    ),
  variants: {
    "hidden-warm": {
      note: "The cache is still warm (3:12 left): no chip; a send reads the cache and acpmux compacts nothing.",
      props: { cacheLeftMs: 192_000 },
      play: chipReads(null),
    },
    "hidden-setting-off": {
      note: "Expired, but acpmux will not compact on return (the setting is off or the chat is under its token floor): no chip, and the send carries no choice.",
      props: { compactOnReturn: false, cacheLeftMs: 0 },
      play: chipReads(null),
    },
    "hidden-running": {
      note: "Expired while a turn runs: a prompt now queues or steers, so no chip.",
      props: { cacheLeftMs: 0, running: true },
      play: chipReads(null),
    },
    compact: {
      note: 'Expired, idle, text typed: Compact · 312K beside Send. Enter compacts first, then sends (`cacheCompact: "compact"`).',
      props: { cacheLeftMs: 0 },
      play: chipReads("Compact · 312K"),
    },
    keep: {
      note: 'One click flips it to Keep: the send goes cold, uncompacted (`cacheCompact: "keep"`). Another click flips it back; each send resets it to Compact.',
      props: { cacheLeftMs: 0 },
      play: flipToKeep,
    },
  },
});
