// l10n-allow-file: development workbench labels, not shipped UI.
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { SCENARIOS, scenarioFrame, selectedScenario } from "./scenarios";
import { Overview } from "./Overview";
import "../../pages/shared/desktop.css";
import "./workbench.css";

type View = "scenario" | "overview";

export function Workbench() {
  const initial = new URLSearchParams(location.search);
  const [selected, setScenario] = useState(() => selectedScenario(initial.get("scenario")));
  const scenario = selectedScenario(selected.id);
  const [view, setView] = useState<View>(() => (initial.get("view") === "overview" ? "overview" : "scenario"));
  const [replay, setReplay] = useState(0);
  const [status, setStatus] = useState("Loading fixture…");
  const frame = useRef<HTMLIFrameElement>(null);
  const toolbar = useRef<HTMLDivElement>(null);
  const overviewScroll = useRef(0);
  const previousView = useRef(view);
  const src = scenarioFrame(scenario, "dark", 760);
  const index = SCENARIOS.findIndex((item) => item.id === scenario.id);
  const changeView = (next: View) => {
    if (view === "overview") overviewScroll.current = window.scrollY;
    setView(next);
  };

  useEffect(() => {
    const url = new URL(location.href);
    url.searchParams.set("scenario", scenario.id);
    url.searchParams.set("appearance", "dark");
    url.searchParams.set("width", "760");
    if (view === "overview") url.searchParams.set("view", "overview");
    else url.searchParams.delete("view");
    if (view === "scenario") url.hash = "";
    history.replaceState(null, "", url);
    setStatus("Loading fixture…");
  }, [scenario.id, view, replay]);

  useLayoutEffect(() => {
    if (previousView.current === view) return;
    previousView.current = view;
    window.scrollTo({ top: view === "overview" ? overviewScroll.current : 0 });
  }, [view]);

  useEffect(() => {
    const node = toolbar.current;
    if (!node) return;
    const observer = new ResizeObserver(([entry]) => {
      if (entry)
        node.parentElement?.style.setProperty(
          "--parity-toolbar-height",
          `${entry.borderBoxSize[0]?.blockSize ?? entry.contentRect.height}px`,
        );
    });
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const receive = (event: MessageEvent) => {
      if (event.origin !== location.origin || event.source !== frame.current?.contentWindow) return;
      if (event.data?.type !== "cmux-gallery-stage") return;
      if (event.data.status === "ready") setStatus("Ready · interactive mock");
      else if (event.data.status === "error") setStatus(`Fixture error: ${String(event.data.message)}`);
    };
    window.addEventListener("message", receive);
    return () => window.removeEventListener("message", receive);
  }, []);

  return (
    <main className="parity-workbench">
      <div className="parity-toolbar" ref={toolbar}>
        <header>
          <h1>Chat scenarios</h1>
          <fieldset className="parity-mode" aria-label="Scenario view">
            <button type="button" aria-pressed={view === "overview"} onClick={() => changeView("overview")}>
              All scenarios · {SCENARIOS.length}
            </button>
            <button type="button" aria-pressed={view === "scenario"} onClick={() => changeView("scenario")}>
              One scenario
            </button>
          </fieldset>
          <a href="/gallery/">Full gallery</a>
        </header>
        {view === "scenario" && (
          <div className="parity-controls">
            <label>
              <span className="parity-sr-only">Scenario</span>
              <select value={scenario.id} onChange={(event) => setScenario(selectedScenario(event.target.value))}>
                {[...new Set(SCENARIOS.map((item) => item.group))].map((group) => (
                  <optgroup key={group} label={group}>
                    {SCENARIOS.filter((item) => item.group === group).map((item) => (
                      <option key={item.id} value={item.id}>
                        {item.title}
                      </option>
                    ))}
                  </optgroup>
                ))}
              </select>
            </label>
            <fieldset className="parity-sequence" aria-label="Browse scenarios">
              <button
                type="button"
                onClick={() => setScenario(SCENARIOS[(index + SCENARIOS.length - 1) % SCENARIOS.length]!)}
              >
                Previous
              </button>
              <span>
                {index + 1} / {SCENARIOS.length}
              </span>
              <button type="button" onClick={() => setScenario(SCENARIOS[(index + 1) % SCENARIOS.length]!)}>
                Next
              </button>
            </fieldset>
            <button type="button" onClick={() => setReplay((value) => value + 1)}>
              {scenario.script ? "Replay lifecycle" : "Reset scenario"}
            </button>
            <a href={src} target="_blank" rel="noreferrer">
              Open fixture
            </a>
          </div>
        )}
      </div>
      {view === "overview" ? (
        <Overview
          onSelect={(id) => {
            setScenario(selectedScenario(id));
            changeView("scenario");
          }}
        />
      ) : (
        <>
          <section className="parity-description" aria-label="Scenario instructions">
            <h2>{scenario.title}</h2>
            <p>{scenario.inspect}</p>
            <output className="parity-status">{status}</output>
          </section>
          <div className="parity-stage">
            <iframe
              key={`${src}:${replay}`}
              ref={frame}
              src={src}
              title={scenario.title}
              style={{ width: 760, maxWidth: "100%" }}
            />
          </div>
        </>
      )}
      <footer>Interactive scenarios use mock data. Open one to try scrolling, folds, output, and copy.</footer>
    </main>
  );
}

const host = document.getElementById("workbench");
if (host) {
  const root: Root = import.meta.hot?.data.workbenchRoot ?? createRoot(host);
  if (import.meta.hot) import.meta.hot.data.workbenchRoot = root;
  root.render(<Workbench />);
}
