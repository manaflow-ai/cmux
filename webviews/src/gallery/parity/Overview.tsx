// l10n-allow-file: development workbench labels, not shipped UI.
import { useEffect, useRef, useState, type MouseEvent } from "react";
import { SCENARIOS, scenarioFrame, type Scenario } from "./scenarios";
import "./overview.css";

export const OVERVIEW_PREVIEW_LIMIT = 4;
const FRAME_HEIGHT = 560;
const WIDTH = 760;

export function scenarioHref(id: string, base: string): string {
  const url = new URL(base);
  url.searchParams.set("scenario", id);
  url.searchParams.set("appearance", "dark");
  url.searchParams.set("width", String(WIDTH));
  url.searchParams.delete("view");
  url.hash = "";
  return url.href;
}

function Preview({ scenario }: { scenario: Scenario }) {
  const host = useRef<HTMLDivElement>(null);
  const [scale, setScale] = useState<number>();
  useEffect(() => {
    const node = host.current;
    if (!node) return;
    const observer = new ResizeObserver(([entry]) => {
      if (entry) setScale(Math.min(1, entry.contentRect.width / WIDTH));
    });
    observer.observe(node);
    return () => observer.disconnect();
  }, []);
  return (
    <div className="parity-overview__scaled" ref={host}>
      {scale !== undefined && (
        <iframe
          src={scenarioFrame(scenario, "dark", WIDTH)}
          title={`${scenario.title} preview`}
          tabIndex={-1}
          aria-hidden="true"
          width={WIDTH}
          height={FRAME_HEIGHT}
          style={{ transform: `scale(${scale})` }}
        />
      )}
    </div>
  );
}

export function Overview({ onSelect }: { onSelect(id: string): void }) {
  const root = useRef<HTMLDivElement>(null);
  const [mounted, setMounted] = useState<ReadonlySet<string>>(() => new Set());
  const groups = [...new Set(SCENARIOS.map((scenario) => scenario.group))];
  useEffect(() => {
    const node = root.current;
    if (!node) return;
    const nearby = new Map<string, Element>();
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const id = (entry.target as HTMLElement).dataset.parityPreview;
          if (!id) continue;
          if (entry.isIntersecting) nearby.set(id, entry.target);
          else nearby.delete(id);
        }
        const next = new Set(
          [...nearby]
            .map(([id, target]) => {
              const rect = target.getBoundingClientRect();
              return [id, Math.abs(rect.top + rect.height / 2 - window.innerHeight / 2)] as const;
            })
            .sort((a, b) => a[1] - b[1])
            .slice(0, OVERVIEW_PREVIEW_LIMIT)
            .map(([id]) => id),
        );
        setMounted((current) =>
          current.size === next.size && [...next].every((id) => current.has(id)) ? current : next,
        );
      },
      { rootMargin: "200px 0px" },
    );
    for (const preview of node.querySelectorAll("[data-parity-preview]")) observer.observe(preview);
    return () => observer.disconnect();
  }, []);

  const select = (event: MouseEvent<HTMLAnchorElement>, id: string) => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    onSelect(id);
  };
  return (
    <div className="parity-overview" ref={root}>
      <nav className="parity-overview__groups" aria-label="Scenario groups">
        {groups.map((group, index) => (
          <a key={group} href={`#scenario-group-${index}`}>
            {group}
          </a>
        ))}
      </nav>
      <p className="parity-overview__instructions">
        Scroll to compare all {SCENARIOS.length} scenarios. Open a scenario to interact, expand rows, and replay it.
      </p>
      {groups.map((group, index) => (
        <section
          key={group}
          className="parity-overview__group"
          id={`scenario-group-${index}`}
          aria-labelledby={`scenario-group-title-${index}`}
        >
          <h2 id={`scenario-group-title-${index}`}>{group}</h2>
          <div className="parity-overview__grid">
            {SCENARIOS.filter((scenario) => scenario.group === group).map((scenario) => (
              <article className="parity-overview__card" key={scenario.id}>
                <div className="parity-overview__card-heading">
                  <h3>{scenario.title}</h3>
                  <a href={scenarioHref(scenario.id, location.href)} onClick={(event) => select(event, scenario.id)}>
                    Open interactive scenario
                  </a>
                </div>
                <p className="parity-overview__inspect">{scenario.inspect}</p>
                <div className="parity-overview__preview" data-parity-preview={scenario.id}>
                  {mounted.has(scenario.id) ? <Preview scenario={scenario} /> : <span>Preview loads nearby</span>}
                </div>
              </article>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}
