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
            <button
              type="button"
              key={result.key}
              className="backdrop-tile"
              aria-busy={using === result.key}
              disabled={using !== null}
              onClick={() => void use(result.key)}
              /* tooltip-allow: the credit the one-line tile drops (macOS 15 tester: tile text overlapped) */ title={[
                result.title,
                [result.artist, result.date, result.source].filter(Boolean).join(" · "),
              ]
                .filter(Boolean)
                .join("\n")}
            >
              <img className="backdrop-thumb" alt="" src={`museum/${encodeURIComponent(result.key)}`} />
              <span className="backdrop-title">{result.title}</span>
              {(using === result.key || failedKey === result.key) && (
                <span className="backdrop-title backdrop-status">
                  {using === result.key ? t("settingsWindow.artBrowser.downloading") : t("settingsWindow.artBrowser.failed")}
                </span>
              )}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
