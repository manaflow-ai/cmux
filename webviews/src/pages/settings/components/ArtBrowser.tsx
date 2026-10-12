// Browse More Art (cx-t2x.8): searches the open-access museum collections the host asks
// (cmux.settings.art.search) for public-domain works; a click downloads one into the backgrounds
// folder and sets it (cmux.settings.art.use). Thumbnails come from the host at museum/<key>.
import { useState } from "react";
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

  return (
    <div className="art-browser" data-card="art-browser">
      <form
        className="art-browser-search"
        onSubmit={(event) => {
          event.preventDefault();
          void search();
        }}
      >
        <input
          className="field"
          type="search"
          aria-label={t("settingsWindow.artBrowser.search")}
          placeholder={t("settingsWindow.artBrowser.search")}
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
        <button type="submit" className="button" disabled={status === "searching" || !query.trim()}>
          {t("settingsWindow.artBrowser.find")}
        </button>
        <button type="button" className="button" onClick={onClose}>
          {t("settingsWindow.artBrowser.close")}
        </button>
      </form>
      <p className="row-help">{t("settingsWindow.artBrowser.help")}</p>
      {status === "searching" && <p className="row-help">{t("settingsWindow.artBrowser.searching")}</p>}
      {status === "done" && results.length === 0 && <p className="row-help">{t("settingsWindow.artBrowser.none")}</p>}
      {status === "failed" && <p className="row-help">{t("settingsWindow.artBrowser.none")}</p>}
      {results.length > 0 && (
        <div className="backdrop-grid">
          {results.map((result) => (
            <button
              type="button"
              key={result.key}
              className="backdrop-tile"
              aria-busy={using === result.key}
              disabled={using !== null}
              aria-label={`${result.title} — ${result.artist}`}
              onClick={() => void use(result.key)}
            >
              <img className="backdrop-thumb" alt="" src={`museum/${encodeURIComponent(result.key)}`} />
              <span className="backdrop-title">{result.title}</span>
              <span className="row-help">
                {using === result.key
                  ? t("settingsWindow.artBrowser.downloading")
                  : failedKey === result.key
                    ? t("settingsWindow.artBrowser.failed")
                    : [result.artist, result.date, result.source].filter(Boolean).join(" · ")}
              </span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
