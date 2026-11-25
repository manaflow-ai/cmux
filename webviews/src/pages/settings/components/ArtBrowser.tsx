// Browse More Art (cx-t2x.8): searches the open-access museum collections the host asks
// (cmux.settings.art.search) for public-domain works; a click downloads one into the backgrounds
// folder and sets it (cmux.settings.art.use). Thumbnails come from the host at museum/<key>.
import { memo, useState } from "react";
import { useStableHandlers } from "../../../agent-session/acpmux/stableHandlers";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { useStore } from "../context";
import type { MuseumArtResult } from "../ops";
import { t } from "../strings";

type Status = "idle" | "searching" | "done" | "failed";

export function ArtBrowser({ onClose }: { onClose: () => void }) {
  const store = useStore();
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<MuseumArtResult[]>([]);
  const [status, setStatus] = useState<Status>("idle");
  const [using, setUsing] = useState<string | null>(null);
  const [failedKey, setFailedKey] = useState<string | null>(null);

  const search = async () => {
    const text = query.trim();
    if (!text) return;
    setStatus("searching");
    const found = await store.searchMuseumArt(text);
    setResults(found ?? []);
    setStatus(found ? "done" : "failed");
  };
  const use = async (key: string) => {
    setUsing(key);
    setFailedKey(null);
    const ok = await store.useMuseumArt(key);
    setUsing(null);
    if (!ok) setFailedKey(key);
  };
  const { onUse } = useStableHandlers({ onUse: (key: string) => void use(key) });

  return (
    <div className="art-browser" data-card="art-browser">
      <form
        className="art-browser-search"
        onSubmit={(event) => {
          event.preventDefault();
          void search();
        }}
      >
        <Input
          className="field"
          type="search"
          aria-label={t("settingsWindow.artBrowser.search")}
          placeholder={t("settingsWindow.artBrowser.search")}
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
        <Button type="submit" className="button" disabled={status === "searching" || !query.trim()}>
          {t("settingsWindow.artBrowser.find")}
        </Button>
        <Button type="button" className="button" onClick={onClose}>
          {t("settingsWindow.artBrowser.close")}
        </Button>
      </form>
      <p className="row-help">{t("settingsWindow.artBrowser.help")}</p>
      <output className="row-help">
        {status === "searching"
          ? t("settingsWindow.artBrowser.searching")
          : status === "failed" || (status === "done" && results.length === 0)
            ? t("settingsWindow.artBrowser.none")
            : null}
      </output>
      {results.length > 0 && (
        <div className="backdrop-grid">
          {results.map((result) => (
            <ArtTile
              key={result.key}
              artKey={result.key}
              title={result.title}
              artist={result.artist}
              date={result.date}
              source={result.source}
              using={using === result.key}
              failed={failedKey === result.key}
              disabled={using !== null}
              onUse={onUse}
            />
          ))}
        </div>
      )}
    </div>
  );
}

/**
 * One work. The host sends at most 12 per collection (MuseumArtSearch's `limit`), so the grid is
 * small; its props are strings and flags, so a keystroke in the search field or another tile's
 * download leaves it be.
 */
const ArtTile = memo(function ArtTile({
  artKey,
  title,
  artist,
  date,
  source,
  using,
  failed,
  disabled,
  onUse,
}: {
  artKey: string;
  title: string;
  artist: string;
  date: string;
  source: string;
  using: boolean;
  failed: boolean;
  disabled: boolean;
  onUse: (key: string) => void;
}) {
  return (
    <button
      type="button"
      className="backdrop-tile"
      data-art-tile={artKey}
      aria-busy={using}
      disabled={disabled}
      onClick={() => onUse(artKey)}
      /* tooltip-allow: the credit the one-line tile drops (macOS 15 tester: tile text overlapped) */ title={[
        title,
        [artist, date, source].filter(Boolean).join(" · "),
      ]
        .filter(Boolean)
        .join("\n")}
    >
      <img className="backdrop-thumb" alt="" src={`museum/${encodeURIComponent(artKey)}`} />
      <span className="backdrop-title">{title}</span>
      {(using || failed) && (
        <span className="backdrop-title backdrop-status">
          {using ? t("settingsWindow.artBrowser.downloading") : t("settingsWindow.artBrowser.failed")}
        </span>
      )}
    </button>
  );
});
