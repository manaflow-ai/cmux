// Mermaid and Vega(-Lite) blocks, rendered from the classic viewer's bundled libraries
// (Resources/markdown-viewer/mermaid.min.js, vega.min.js + vega-lite.min.js), which the host serves
// as same-origin scripts (`<libBase>mermaid.js`, `<libBase>vega.js`). The page runs under the
// strict PageCSP (no 'unsafe-eval'): Vega's expression compiler uses Function, so Vega runs with
// the AST interpreter (vega-interpreter); Mermaid runs with securityLevel "strict".
type MermaidAPI = {
  initialize(config: Record<string, unknown>): void;
  render(id: string, source: string): Promise<{ svg: string }>;
};
type VegaAPI = {
  parse(spec: unknown, config?: unknown, options?: { ast?: boolean }): unknown;
  View: new (
    runtime: unknown,
    options: Record<string, unknown>,
  ) => {
    runAsync(): Promise<unknown>;
    finalize(): void;
  };
};
type VegaLiteAPI = { compile(spec: unknown, options?: { config?: unknown }): { spec: unknown } };

export type DiagramLibrary = "mermaid" | "vega";

/** Loads one host library script once; resolves when its globals exist. */
export class DiagramLibraries {
  private readonly loads = new Map<DiagramLibrary, Promise<void>>();

  constructor(private readonly libURL: (name: DiagramLibrary) => string | null) {}

  load(name: DiagramLibrary): Promise<void> {
    let promise = this.loads.get(name);
    if (!promise) {
      promise = new Promise<void>((resolve, reject) => {
        const url = this.libURL(name);
        if (!url) return reject(new Error(`no ${name} library`));
        const script = document.createElement("script");
        script.src = url;
        script.async = true;
        script.onload = () => resolve();
        script.onerror = () => reject(new Error(`${name} library failed to load`));
        document.head.append(script);
      });
      promise.catch(() => this.loads.delete(name));
      this.loads.set(name, promise);
    }
    return promise;
  }
}

let mermaidCount = 0;
let mermaidScheme: string | null = null;

const darkScheme = () => globalThis.matchMedia?.("(prefers-color-scheme: dark)").matches === true;

/** Renders a mermaid diagram as SVG into `target`. */
export async function renderMermaid(libraries: DiagramLibraries, source: string, target: HTMLElement): Promise<void> {
  await libraries.load("mermaid");
  const mermaid = (globalThis as { mermaid?: MermaidAPI }).mermaid;
  if (!mermaid) throw new Error("mermaid did not load");
  const scheme = darkScheme() ? "dark" : "default";
  if (mermaidScheme !== scheme) {
    mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: scheme, fontFamily: "inherit" });
    mermaidScheme = scheme;
  }
  const { svg } = await mermaid.render(`cmux-mermaid-${++mermaidCount}`, source);
  const parsed = new DOMParser().parseFromString(svg, "image/svg+xml").documentElement;
  if (parsed.nodeName !== "svg") throw new Error("mermaid produced no svg");
  target.replaceChildren(document.importNode(parsed, true));
}

const views = new WeakMap<HTMLElement, { finalize(): void }>();

/** Renders a Vega or Vega-Lite spec (JSON) as SVG into `target`, without eval. */
export async function renderVega(
  libraries: DiagramLibraries,
  mode: "vega" | "vega-lite",
  source: string,
  target: HTMLElement,
): Promise<void> {
  const spec = JSON.parse(source) as Record<string, unknown>;
  const [, { expressionInterpreter }] = await Promise.all([libraries.load("vega"), import("vega-interpreter")]);
  const globals = globalThis as { vega?: VegaAPI; vegaLite?: VegaLiteAPI };
  const vega = globals.vega;
  if (!vega) throw new Error("vega did not load");
  // The chart sits on the page backdrop (no white card), with readable axes in dark mode.
  const config = { background: "transparent", ...(darkScheme() ? darkVegaConfig : {}) };
  let vegaSpec: Record<string, unknown> = spec;
  if (mode === "vega-lite") {
    if (!globals.vegaLite) throw new Error("vega-lite did not load");
    vegaSpec = globals.vegaLite.compile(spec, { config }).spec as Record<string, unknown>;
  }
  const runtime = vega.parse({ ...vegaSpec, background: spec.background ?? "transparent" }, config, { ast: true });
  const container = document.createElement("div");
  const view = new vega.View(runtime, {
    expr: expressionInterpreter,
    renderer: "svg",
    container,
    hover: true,
  });
  await view.runAsync();
  views.get(target)?.finalize();
  views.set(target, view);
  target.replaceChildren(container);
}

const darkVegaConfig = {
  axis: { domainColor: "#888", gridColor: "#444", tickColor: "#888", labelColor: "#ccc", titleColor: "#ddd" },
  legend: { labelColor: "#ccc", titleColor: "#ddd" },
  title: { color: "#ddd" },
  view: { stroke: "#444" },
};

/** Renders a diagram block; on failure shows `errorText` and the reason. */
export function renderDiagram(
  libraries: DiagramLibraries,
  language: string,
  source: string,
  target: HTMLElement,
  errorText: string,
): void {
  target.dataset.state = "rendering";
  const done = (promise: Promise<void>) =>
    promise.then(
      () => {
        target.dataset.state = "rendered";
      },
      (error: unknown) => {
        target.dataset.state = "error";
        const message = document.createElement("div");
        message.className = "md-diagram-error";
        message.textContent = `${errorText} ${error instanceof Error ? error.message : String(error)}`;
        target.replaceChildren(message);
      },
    );
  if (language === "mermaid") void done(renderMermaid(libraries, source, target));
  else void done(renderVega(libraries, language === "vega" ? "vega" : "vega-lite", source, target));
}
