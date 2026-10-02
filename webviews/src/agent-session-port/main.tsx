import { StrictMode, Suspense, lazy, use, useSyncExternalStore, type ComponentType } from "react";
import { createRoot } from "react-dom/client";
import references from "../scripts/references.json";
import "./shell/base.css";

// Each screen lives in src/screens/<id>.tsx and default-exports a component.
// The file name is the screen id from scripts/references.json.
// Helpers that live beside screens (`*.data.tsx`) are not screens.
const modules = import.meta.glob<{ default: ComponentType }>([
  "./screens/*.tsx",
  "!./screens/*.data.tsx",
]);
const screens = new Map(
  Object.entries(modules).map(([path, load]) => [
    path.slice("./screens/".length, -".tsx".length),
    lazy(load),
  ]),
);

// html[data-screen] gives a screen its transparent, unscrolled page (base.css). It follows
// the hash from the hashchange event, outside React's render.
const syncScreenAttr = () => {
  const id = location.hash.slice(2);
  if (id && screens.has(id)) document.documentElement.dataset.screen = id;
  else delete document.documentElement.dataset.screen;
};
syncScreenAttr();
window.addEventListener("hashchange", syncScreenAttr);

const subscribe = (cb: () => void) => {
  window.addEventListener("hashchange", cb);
  return () => window.removeEventListener("hashchange", cb);
};
const useHash = () => useSyncExternalStore(subscribe, () => location.hash.slice(2));

type Report = Record<string, { mismatchPercent: number; at: string }>;

// Mismatch numbers come from the last `node scripts/compare.mjs` run (out/report.json, served
// by the dev server). Fetched once per page load and read with use() under Suspense.
let reportRequest: Promise<Report> | undefined;
const loadReport = () =>
  (reportRequest ??= fetch("/out/report.json")
    .then((r) => (r.ok ? (r.json() as Promise<Report>) : ({} as Report)))
    .catch((): Report => ({})));

const tone = (pct: number | undefined) =>
  pct === undefined ? "is-missing" : pct < 0.1 ? "is-good" : pct < 0.5 ? "is-ok" : "is-bad";

function Gallery() {
  const report = use(loadReport());
  const entries = Object.entries(references as Record<string, { reference: string }>);
  return (
    <ul className="atlas-index__grid">
      {entries.map(([id, { reference }]) => {
        const pct = report[id]?.mismatchPercent;
        return (
          <li key={id} className="atlas-index__card">
            <a href={`#/${id}`} className="atlas-index__thumb">
              {/* Reference captures are large PNGs: lazy, async-decoded, fixed aspect box. */}
              <img src={`/${reference}`} alt="" loading="lazy" decoding="async" />
            </a>
            <div className="atlas-index__meta">
              <a href={`#/${id}`}>{id}</a>
              {screens.has(id) ? (
                <a
                  className={`atlas-index__pct ${tone(pct)}`}
                  href={`/out/${id}/side.png`}
                  target="_blank"
                  rel="noreferrer"
                  title="Reference | clone"
                >
                  {pct === undefined ? "not measured" : `${pct.toFixed(3)}%`}
                </a>
              ) : (
                <span className="atlas-index__pct is-missing">missing</span>
              )}
            </div>
          </li>
        );
      })}
    </ul>
  );
}

/** Dev index: every screen's reference thumbnail, a link to the live clone and its mismatch. */
function Index() {
  const ids = Object.keys(references);
  return (
    <main className="atlas-index">
      <h1>Codex atlas clone</h1>
      <p>
        {ids.filter((id) => screens.has(id)).length} of {ids.length} screens implemented. Mismatch
        is the last <code>node scripts/compare.mjs</code> result; click it for reference | clone.
      </p>
      <Suspense fallback={<p>Loading report…</p>}>
        <Gallery />
      </Suspense>
    </main>
  );
}

function App() {
  const id = useHash();
  const Screen = id ? screens.get(id) : undefined;
  if (!Screen) return <Index />;
  return (
    <Suspense fallback={null}>
      <Screen />
    </Suspense>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
