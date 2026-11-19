// Add YouTube Video… (video-wallpapers): a pasted YouTube link, an optional Start and End and a
// Quality become one `youtube:` background id, chosen through the picker's own `choose`, so
// All Workspaces, This Workspace, Light and Dark treat it as any other tile. The thumbnail is the
// host's `backdrop/<id>` (the page's CSP loads no remote image), the same route every tile uses.
import { useId, useState } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { Select } from "../../../ui/Select";
import type { HostLists } from "../ops";
import { t } from "../strings";
import {
  formatClock,
  parseClock,
  parseYouTubeLink,
  validRange,
  YOUTUBE_DEFAULT_QUALITY,
  YOUTUBE_QUALITIES,
  youtubeId,
} from "../youtubeWallpaper";

/** How the form is laid out (gallery variants): `card`, the thumbnail beside the fields (shipped);
 * `stacked`, the thumbnail above the fields; `inline`, everything on one row. */
export type YouTubeAddDesign = "card" | "stacked" | "inline";

/** The thumbnail of any background id, as a tile draws it (encoded twice; see HostCards). */
export const backdropThumbSrc = (id: string) => `backdrop/${encodeURIComponent(encodeURIComponent(id))}`;

/** What the form would write, or why it cannot yet: `null` id with a reason key, or no reason while empty. */
export function youtubeDraft(
  link: string,
  startText: string,
  endText: string,
  quality: number,
): { id: string | null; video: string | null; problem: string | null } {
  const parsed = link.trim() ? parseYouTubeLink(link) : null;
  if (!parsed) {
    return { id: null, video: null, problem: link.trim() ? "settingsWindow.backdropPicker.youtubeNotVideo" : null };
  }
  const start = parseClock(startText);
  const end = parseClock(endText);
  if (start === null || end === null) {
    return { id: null, video: parsed.video, problem: "settingsWindow.backdropPicker.youtubeBadClock" };
  }
  // A link's own `t=` is the start unless one is typed.
  const from = start ?? parsed.start;
  const to = end ?? null;
  if (!validRange(from, to)) {
    return { id: null, video: parsed.video, problem: "settingsWindow.backdropPicker.youtubeBadRange" };
  }
  return { id: youtubeId({ video: parsed.video, start: from, end: to, quality }), video: parsed.video, problem: null };
}

/** Whether the picker offers Add YouTube Video…: the one place a gate (`youtube_wallpapers`) is read. */
export function youtubeAddOffered(host: Pick<HostLists, "youtube_wallpapers"> | null | undefined): boolean {
  return host?.youtube_wallpapers !== false;
}

/** The Add YouTube Video… tile, last in Moving wallpapers; it opens the form under the group. */
export function YouTubeAddTile({ open, onToggle }: { open: boolean; onToggle: () => void }) {
  return (
    <button type="button" className="backdrop-tile" aria-expanded={open} data-youtube-add="" onClick={onToggle}>
      <span className="backdrop-thumb backdrop-none backdrop-choose" aria-hidden="true">
        ▶
      </span>
      <span className="backdrop-title">{t("settingsWindow.backdropPicker.youtubeAdd")}</span>
      <span className="row-help">{t("settingsWindow.backdropPicker.youtubeAddHelp")}</span>
    </button>
  );
}

export function YouTubeAdd({
  onChoose,
  onClose,
  design = "card",
  initial = {},
  thumbSrc = backdropThumbSrc,
}: {
  /** Writes the id as a tile click does; resolves once it is the background. */
  onChoose: (id: string) => Promise<void> | void;
  onClose: () => void;
  design?: YouTubeAddDesign;
  /** What the fields open with (the gallery's filled states); empty by default. */
  initial?: { link?: string; start?: string; end?: string; quality?: number };
  /** Where a background id's thumbnail is (the gallery's sample pictures); the host's route by default. */
  thumbSrc?: (id: string) => string;
}) {
  const [link, setLink] = useState(initial.link ?? "");
  const [startText, setStart] = useState(initial.start ?? "");
  const [endText, setEnd] = useState(initial.end ?? "");
  const [quality, setQuality] = useState(initial.quality ?? YOUTUBE_DEFAULT_QUALITY);
  const [busy, setBusy] = useState(false);
  // A thumbnail the host could not fetch (offline, a removed video) leaves the empty box.
  const [failed, setFailed] = useState<string | null>(null);
  const field = useId();
  const draft = youtubeDraft(link, startText, endText, quality);
  // The link's own time stands in the Start field until one is typed.
  const linkStart = link.trim() ? (parseYouTubeLink(link)?.start ?? 0) : 0;
  const submit = async () => {
    if (!draft.id) return;
    setBusy(true);
    await onChoose(draft.id);
    setBusy(false);
    onClose();
  };
  return (
    <div className="art-browser youtube-add" data-card="youtube-add" data-design={design}>
      {/* A fixed 16:9 box before and after a link is read, so the form never changes height. */}
      <span className="youtube-add-preview" aria-hidden="true">
        {draft.video && failed !== draft.video ? (
          <img
            className="backdrop-thumb"
            alt=""
            src={thumbSrc(`youtube:${draft.video}`)}
            onError={() => setFailed(draft.video)}
          />
        ) : (
          <span className="backdrop-thumb backdrop-none backdrop-choose">▶</span>
        )}
      </span>
      <form
        className="youtube-add-fields"
        onSubmit={(event) => {
          event.preventDefault();
          void submit();
        }}
      >
        <Input
          className="field youtube-add-link"
          type="url"
          aria-label={t("settingsWindow.backdropPicker.youtubeLink")}
          placeholder={t("settingsWindow.backdropPicker.youtubeLink")}
          value={link}
          onChange={(event) => setLink(event.target.value)}
        />
        <div className="youtube-add-options">
          <label className="youtube-add-option" htmlFor={`${field}-start`}>
            <span className="row-help">{t("settingsWindow.backdropPicker.youtubeStart")}</span>
            <Input
              id={`${field}-start`}
              data-youtube-field="start"
              className="field youtube-add-time"
              inputMode="numeric"
              placeholder={formatClock(linkStart)}
              value={startText}
              onChange={(event) => setStart(event.target.value)}
            />
          </label>
          <label className="youtube-add-option" htmlFor={`${field}-end`}>
            <span className="row-help">{t("settingsWindow.backdropPicker.youtubeEnd")}</span>
            <Input
              id={`${field}-end`}
              data-youtube-field="end"
              className="field youtube-add-time"
              inputMode="numeric"
              placeholder={t("settingsWindow.backdropPicker.youtubeToEnd")}
              value={endText}
              onChange={(event) => setEnd(event.target.value)}
            />
          </label>
          <span className="youtube-add-option">
            <span className="row-help">{t("settingsWindow.backdropPicker.youtubeQuality")}</span>
            <Select
              className="select youtube-add-quality"
              label={t("settingsWindow.backdropPicker.youtubeQuality")}
              value={String(quality)}
              closeOnPick
              options={YOUTUBE_QUALITIES.map((height) => ({
                value: String(height),
                label: t("settingsWindow.backdropPicker.youtubeQualityHeight", String(height)),
              }))}
              onChange={(value) => setQuality(Number(value))}
            />
          </span>
        </div>
        <div className="youtube-add-actions">
          <Button type="submit" className="button" disabled={busy || draft.id === null}>
            {t("settingsWindow.backdropPicker.youtubeSet")}
          </Button>
          <Button type="button" className="button" onClick={onClose}>
            {t("settingsWindow.artBrowser.close")}
          </Button>
          <output className="row-help youtube-add-problem">{draft.problem ? t(draft.problem) : ""}</output>
        </div>
      </form>
    </div>
  );
}
