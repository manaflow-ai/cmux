// Mermaid and Vega(-Lite) blocks, rendered from the classic viewer's bundled libraries
// (Resources/markdown-viewer/ondine.min.js, mermaid.min.js, vega.min.js + vega-lite.min.js), which the
// host serves as same-origin scripts (`<libBase>ondine.js`, `<libBase>mermaid.js`, `<libBase>vega.js`).
// The page runs under the strict PageCSP plus 'wasm-unsafe-eval' (no 'unsafe-eval'): Vega's
// expression compiler uses Function, so Vega runs with the AST interpreter (vega-interpreter).
//
// Mermaid source draws with Ondine (github.com/wevm/ondine, evaluation in
// plans/cmux-next/mermaid-ondine-EVAL.md): a Rust compiler in WebAssembly with no imports, so it
// cannot touch the page; it returns SVG text. Ondine always renders; Mermaid 11 (securityLevel
// "strict") draws only a source Ondine refuses, with no flag or setting to choose it. Either SVG is parsed
// as HTML (Mermaid writes HTML labels), cleaned of script, handlers and script URLs, then inserted.
type MermaidAPI = {
  initialize(config: Record<string, unknown>): void;
  render(id: string, source: string): Promise<{ svg: string }>;
};
type OndineAPI = {
  wasm: string;
  create(options: { modules: Record<string, string> }): { render(source: string): { svg: string } };
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

export type DiagramLibrary = "ondine" | "mermaid" | "vega";

/** The global each library script defines. */
const LIBRARY_GLOBALS: Record<DiagramLibrary, string> = { ondine: "ondine", mermaid: "mermaid", vega: "vega" };

/** Loads one host library script once; resolves when its globals exist. */
export class DiagramLibraries {
  private readonly loads = new Map<DiagramLibrary, Promise<void>>();

  constructor(private readonly libURL: (name: DiagramLibrary) => string | null) {}

  load(name: DiagramLibrary): Promise<void> {
    let promise = this.loads.get(name);
    if (!promise && (globalThis as Record<string, unknown>)[LIBRARY_GLOBALS[name]] !== undefined) {
      promise = Promise.resolve();
      this.loads.set(name, promise);
    }
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

let ondineRenderer: ReturnType<OndineAPI["create"]> | null = null;

/** Renders Mermaid `source` with Ondine; throws Ondine's diagnostic for a source it refuses. */
async function renderOndine(libraries: DiagramLibraries, source: string): Promise<string> {
  await libraries.load("ondine");
  const ondine = (globalThis as { ondine?: OndineAPI }).ondine;
  if (!ondine) throw new Error("ondine did not load");
  ondineRenderer ??= ondine.create({ modules: { all: ondine.wasm } });
  return ondineRenderer.render(source).svg;
}

/** Renders Mermaid `source` with Mermaid 11. */
async function renderMermaidJS(libraries: DiagramLibraries, source: string): Promise<string> {
  await libraries.load("mermaid");
  const mermaid = (globalThis as { mermaid?: MermaidAPI }).mermaid;
  if (!mermaid) throw new Error("mermaid did not load");
  const scheme = darkScheme() ? "dark" : "default";
  if (mermaidScheme !== scheme) {
    mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: scheme, fontFamily: "inherit" });
    mermaidScheme = scheme;
  }
  return (await mermaid.render(`cmux-mermaid-${++mermaidCount}`, source)).svg;
}

/** The latest draw into each target: a render still running for an earlier one must not write over it. */
const draws = new WeakMap<HTMLElement, number>();
const views = new WeakMap<HTMLElement, { finalize(): void }>();

/** Starts a draw into `target`; the returned check is false once a newer draw or `cancelDiagram` took over. */
function beginDraw(target: HTMLElement): () => boolean {
  const mine = (draws.get(target) ?? 0) + 1;
  draws.set(target, mine);
  return () => draws.get(target) === mine;
}

/**
 * Cancels the draw into `target` and stops the Vega view it holds (its timers and window listeners):
 * the block redrew from another source or left the page. A render still running for it drops its result.
 */
export function cancelDiagram(target: HTMLElement): void {
  draws.set(target, (draws.get(target) ?? 0) + 1);
  views.get(target)?.finalize();
  views.delete(target);
}

/**
 * Renders a mermaid diagram as SVG into `target` with Ondine, falling back to Mermaid for a source
 * Ondine refuses; when both refuse, Ondine's reason is the error.
 */
export async function renderMermaid(libraries: DiagramLibraries, source: string, target: HTMLElement): Promise<void> {
  const current = beginDraw(target);
  let svg: string;
  try {
    svg = await renderOndine(libraries, source);
  } catch (ondineError) {
    try {
      svg = await renderMermaidJS(libraries, source);
    } catch {
      throw ondineError;
    }
  }
  if (!current()) return;
  target.replaceChildren(document.importNode(cleanSVG(svg), true));
}

const SCRIPT_URL = /^(javascript|data|vbscript):/i;
/** `text` without ASCII whitespace and control characters, which browsers drop before a URL scheme. */
const withoutControls = (text: string) =>
  Array.from(text)
    .filter((char) => char.charCodeAt(0) > 32)
    .join("");
const BLOCKED_ELEMENTS = new Set(["script", "iframe", "object", "embed", "link", "meta", "base", "form"]);

/**
 * Parses renderer output as HTML (Mermaid writes HTML labels in `<foreignObject>`, such as an unclosed
 * `<br>`, which XML parsing stops at) and removes what could run script or leave the page: script-like
 * elements, `on*` handlers, and `javascript:`/`data:`/`vbscript:` links and sources.
 */
export function cleanSVG(text: string): SVGSVGElement {
  const svg = new DOMParser().parseFromString(text, "text/html").body.querySelector("svg");
  if (!svg) throw new Error("mermaid produced no svg");
  for (const element of [svg, ...svg.querySelectorAll("*")]) {
    if (BLOCKED_ELEMENTS.has(element.localName.toLowerCase())) {
      element.remove();
      continue;
    }
    // A copy: removing an attribute changes the live NamedNodeMap.
    for (const attribute of Array.from(element.attributes)) {
      const name = attribute.name.toLowerCase();
      const url = name === "href" || name.endsWith(":href") || name === "src" || name === "action";
      if (name.startsWith("on") || (url && SCRIPT_URL.test(withoutControls(attribute.value)))) {
        element.removeAttribute(attribute.name);
      }
    }
  }
  return svg as unknown as SVGSVGElement;
}

/** Renders a Vega or Vega-Lite spec (JSON) as SVG into `target`, without eval. */
export async function renderVega(
  libraries: DiagramLibraries,
  mode: "vega" | "vega-lite",
  source: string,
  target: HTMLElement,
): Promise<void> {
  const current = beginDraw(target);
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
  // A newer draw or a cancel took over while this one ran: stop its view and leave the target alone.
  if (!current()) {
    view.finalize();
    return;
  }
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
