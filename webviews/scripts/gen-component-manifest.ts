// Agent-first docs for the web component library (webviews/src/ui and webviews/src/kit): one
// machine-readable manifest, an llms.txt index and one markdown page per component, all read from
// the source with the TypeScript compiler API so they cannot drift from it.
//
//   bun scripts/gen-component-manifest.ts           write the outputs
//   bun scripts/gen-component-manifest.ts --check   fail when the source no longer generates, or not the same twice
//
// Outputs (gitignored, made on demand: no committed generated files; docs only, nothing imports them;
// output is sorted and byte-stable):
//   src/ui/components.generated.json   name, file, tier, props, data-* attributes, gallery entries, status
//   src/ui/llms.txt                    one line per component, linking to its page
//   src/ui/docs/<Name>.md              summary, props, data attributes, gallery entries, an example
//
// A component is an exported, capitalised function or const with a call signature in src/ui or
// src/kit (a *.tsx that is not a test or gallery file), or a name the kit barrel (src/kit/index.ts)
// re-exports. Props are the ones the repo declares; props inherited from a library type (a Base UI
// part, DOM attributes) are summarised under `extends`. The summary is the declaration's JSDoc, else
// the file's leading comment. `@status <ready|experimental|deprecated>` on the declaration sets the
// status; otherwise it is `experimental` when every gallery entry covering it is flagged
// experimental, else `ready`. Gallery entries come from `covers: ["ui/Button.tsx#Button"]` in the
// `*.gallery.tsx` files. `data-*` attributes are the ones the component's own body sets.
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const SRC = join(ROOT, "src");
const UI = join(SRC, "ui");
const KIT = join(SRC, "kit");
const DOCS = join(UI, "docs");
const MANIFEST = join(UI, "components.generated.json");
const LLMS = join(UI, "llms.txt");
const GALLERY_PATH = "/gallery";

type Prop = { name: string; type: string; optional: boolean; doc: string };
type Variant = { name: string; props: string | null; note: string | null };
type Entry = { id: string; title: string; file: string; experimental: boolean; variants: Variant[] };
type Component = {
  name: string;
  file: string;
  tier: "ui" | "kit";
  kitExport: boolean;
  status: string;
  summary: string;
  extends: string[];
  props: Prop[];
  dataAttributes: string[];
  galleryEntries: Entry[];
};

const rel = (file: string) => relative(SRC, file).split("\\").join("/");
const walk = (dir: string): string[] =>
  readdirSync(dir, { withFileTypes: true })
    .flatMap((d) => (d.isDirectory() ? walk(join(dir, d.name)) : [join(dir, d.name)]))
    .sort();
// Gallery fixtures and demo pages (MotionDemos, *.galleryFixtures, *Demo) are not library components.
const isSource = (f: string) =>
  /\.tsx$/.test(f) && !/\.(gallery|test|experiment|galleryFixtures)\.tsx$/.test(f) && !/Demos?\.tsx$/.test(f);
const clean = (s: string) =>
  s
    .replace(/import\("[^"]*"\)\./g, "")
    .replace(/\s+/g, " ")
    .trim();
const oneLine = (s: string) => s.replace(/\s+/g, " ").trim();
const firstSentence = (s: string) => {
  const t = oneLine(s);
  const m = t.match(/^(.+?[.!?])(\s|$)/);
  const sentence = m ? m[1] : t;
  return sentence.length > 220 ? `${sentence.slice(0, 217).trimEnd()}...` : sentence;
};

function galleryEntries(): (Entry & { covers: string[] })[] {
  const out: (Entry & { covers: string[] })[] = [];
  for (const file of walk(SRC).filter((f) => /\.gallery\.tsx$/.test(f))) {
    const sf = ts.createSourceFile(file, readFileSync(file, "utf8"), ts.ScriptTarget.ES2022, true, ts.ScriptKind.TSX);
    const visit = (node: ts.Node) => {
      if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === "componentEntry") {
        const arg = node.arguments[0];
        if (arg && ts.isObjectLiteralExpression(arg)) out.push(readEntry(arg, file, sf));
      }
      ts.forEachChild(node, visit);
    };
    visit(sf);
  }
  return out;
}

const keyName = (p: ts.ObjectLiteralElementLike) =>
  p.name && (ts.isIdentifier(p.name) || ts.isStringLiteral(p.name)) ? p.name.text : null;
const field = (o: ts.ObjectLiteralExpression, key: string) =>
  o.properties.find((p): p is ts.PropertyAssignment => ts.isPropertyAssignment(p) && keyName(p) === key)?.initializer;

function readEntry(o: ts.ObjectLiteralExpression, file: string, sf: ts.SourceFile): Entry & { covers: string[] } {
  const str = (e?: ts.Expression) => (e && ts.isStringLiteralLike(e) ? e.text : "");
  const covers = field(o, "covers");
  const variants = field(o, "variants");
  const vs: Variant[] = [];
  if (variants && ts.isObjectLiteralExpression(variants)) {
    for (const p of variants.properties) {
      const name = keyName(p);
      if (!name || !ts.isPropertyAssignment(p) || !ts.isObjectLiteralExpression(p.initializer)) continue;
      const props = field(p.initializer, "props");
      const note = field(p.initializer, "note");
      vs.push({
        name,
        props: props && ts.isObjectLiteralExpression(props) ? oneLine(props.getText(sf)) : null,
        note: str(note) || null,
      });
    }
  }
  vs.sort((a, b) => a.name.localeCompare(b.name));
  return {
    id: str(field(o, "id")),
    title: str(field(o, "title")),
    file: rel(file),
    experimental: field(o, "experimental")?.kind === ts.SyntaxKind.TrueKeyword,
    variants: vs,
    covers: covers && ts.isArrayLiteralExpression(covers) ? covers.elements.map((e) => str(e)).filter(Boolean) : [],
  };
}

function build(): Component[] {
  const files = [...walk(UI), ...walk(KIT)].filter((f) => isSource(f) || f === join(KIT, "index.ts"));
  const config = ts.getParsedCommandLineOfConfigFile(
    join(ROOT, "tsconfig.json"),
    {},
    {
      ...ts.sys,
      onUnRecoverableConfigFileDiagnostic: (d) => {
        throw new Error(ts.flattenDiagnosticMessageText(d.messageText, "\n"));
      },
    },
  );
  const program = ts.createProgram(files, { ...config!.options, noEmit: true });
  const checker = program.getTypeChecker();
  const entries = galleryEntries();
  const isOwn = (f: string) => !f.includes("/node_modules/");

  const kitBarrel = program.getSourceFile(join(KIT, "index.ts"))!;
  const kitNames = new Set<string>();
  for (const st of kitBarrel.statements) {
    if (!ts.isExportDeclaration(st) || st.isTypeOnly || !st.exportClause || !ts.isNamedExports(st.exportClause))
      continue;
    for (const el of st.exportClause.elements) if (!el.isTypeOnly) kitNames.add(el.name.text);
  }

  const found = new Map<string, Component>();
  const add = (decl: ts.Node, sym: ts.Symbol, name: string) => {
    const sf = decl.getSourceFile();
    const file = rel(sf.fileName);
    if (!/^(ui|kit)\//.test(file) || !isSource(sf.fileName)) return;
    const type = checker.getTypeOfSymbolAtLocation(sym, decl);
    const sig = type.getCallSignatures()[0];
    if (!sig) return;
    const param = sig.parameters[0];
    const props: Prop[] = [];
    const ext = new Set<string>();
    if (param) {
      const pt = checker.getTypeOfSymbolAtLocation(param, decl);
      for (const p of checker.getPropertiesOfType(pt)) {
        const d = p.declarations?.[0];
        if (!d || !isOwn(d.getSourceFile().fileName)) {
          continue;
        }
        const ptype = checker.getTypeOfSymbolAtLocation(p, d);
        props.push({
          name: p.name,
          type: clean(
            checker.typeToString(
              ptype,
              d,
              ts.TypeFormatFlags.NoTruncation | ts.TypeFormatFlags.UseAliasDefinedOutsideCurrentScope,
            ),
          ).replace(/ \| undefined$/, ""),
          optional: (p.flags & ts.SymbolFlags.Optional) !== 0,
          doc: oneLine(ts.displayPartsToString(p.getDocumentationComment(checker))),
        });
      }
      const decl0 = pt.aliasSymbol?.declarations?.[0] ?? pt.symbol?.declarations?.[0];
      if (decl0 && (ts.isInterfaceDeclaration(decl0) || ts.isClassDeclaration(decl0))) {
        for (const h of decl0.heritageClauses ?? []) for (const t of h.types) ext.add(clean(t.getText()));
      } else if (decl0 && ts.isTypeAliasDeclaration(decl0) && ts.isIntersectionTypeNode(decl0.type)) {
        for (const t of decl0.type.types) if (!ts.isTypeLiteralNode(t)) ext.add(clean(t.getText()));
      }
      props.sort((a, b) => a.name.localeCompare(b.name));
    }
    const stmt = ts.findAncestor(decl, (n) => ts.isVariableStatement(n) || ts.isFunctionDeclaration(n)) ?? decl;
    const tags = ts.getJSDocTags(stmt);
    const status = tags.find((t) => t.tagName.text === "status");
    const jsdoc = ts.displayPartsToString(sym.getDocumentationComment(checker));
    const lead = (sf.getFullText().match(/^(?:\s*\/\/[^\n]*\n)+/)?.[0] ?? "")
      .split("\n")
      .map((l) => l.replace(/^\s*\/\/\s?/, ""))
      .filter((l) => !/^l10n-allow/.test(l))
      .join(" ");
    const attrs = new Set<string>();
    const scan = (n: ts.Node) => {
      if (ts.isJsxAttribute(n) && n.name.getText().startsWith("data-")) attrs.add(n.name.getText());
      else if (
        ts.isPropertyAssignment(n) &&
        n.name &&
        (ts.isStringLiteral(n.name) || ts.isIdentifier(n.name)) &&
        /^data-[a-z]/.test(n.name.text)
      )
        attrs.add(n.name.text);
      ts.forEachChild(n, scan);
    };
    scan(stmt);
    const covering = entries.filter((e) => e.covers.includes(`${file}#${name}`));
    const explicit = status && typeof status.comment === "string" ? status.comment.trim() : "";
    found.set(`${file}#${name}`, {
      name,
      file,
      tier: file.startsWith("kit/") ? "kit" : "ui",
      kitExport: kitNames.has(name),
      status: explicit || (covering.length > 0 && covering.every((e) => e.experimental) ? "experimental" : "ready"),
      summary: firstSentence(jsdoc || lead),
      extends: [...ext].sort(),
      props,
      dataAttributes: [...attrs].sort(),
      galleryEntries: covering.map(({ covers: _c, ...e }) => e).sort((a, b) => a.id.localeCompare(b.id)),
    });
  };

  for (const sf of program.getSourceFiles()) {
    const file = rel(sf.fileName);
    if (!/^(ui|kit)\//.test(file) || !isSource(sf.fileName)) continue;
    const mod = checker.getSymbolAtLocation(sf);
    if (!mod) continue;
    for (const ex of checker.getExportsOfModule(mod)) {
      if (!/^[A-Z][A-Za-z0-9]*[a-z][A-Za-z0-9]*$/.test(ex.name)) continue;
      const d = ex.declarations?.[0];
      if (d && d.getSourceFile() === sf) add(d, ex, ex.name);
    }
  }
  // Barrel re-exports that live outside src/ui and src/kit (Icon, Spinner) are listed from where they are defined.
  for (const name of kitNames) {
    if (![...found.values()].some((c) => c.name === name) && /^[A-Z]/.test(name)) {
      const mod = checker.getSymbolAtLocation(kitBarrel)!;
      const ex = checker.getExportsOfModule(mod).find((s) => s.name === name);
      let real = ex;
      if (real && real.flags & ts.SymbolFlags.Alias) real = checker.getAliasedSymbol(real);
      const d = real?.declarations?.[0];
      if (
        d &&
        real &&
        /^[A-Z][A-Za-z0-9]*[a-z]/.test(name) &&
        checker.getTypeOfSymbolAtLocation(real, d).getCallSignatures().length > 0
      ) {
        addOutside(d, real, name);
      }
    }
  }
  function addOutside(d: ts.Node, sym: ts.Symbol, name: string) {
    const sf = d.getSourceFile();
    const file = rel(sf.fileName);
    const stmt = ts.findAncestor(d, (n) => ts.isVariableStatement(n) || ts.isFunctionDeclaration(n)) ?? d;
    const attrs = new Set<string>();
    const scan = (n: ts.Node) => {
      if (ts.isJsxAttribute(n) && n.name.getText().startsWith("data-")) attrs.add(n.name.getText());
      ts.forEachChild(n, scan);
    };
    scan(stmt);
    const covering = entries.filter((e) => e.covers.includes(`${file}#${name}`));
    found.set(`${file}#${name}`, {
      name,
      file,
      tier: "kit",
      kitExport: true,
      status: covering.length > 0 && covering.every((e) => e.experimental) ? "experimental" : "ready",
      summary: firstSentence(ts.displayPartsToString(sym.getDocumentationComment(checker))),
      extends: [],
      props: [],
      dataAttributes: [...attrs].sort(),
      galleryEntries: covering.map(({ covers: _c, ...e }) => e).sort((a, b) => a.id.localeCompare(b.id)),
    });
  }
  return [...found.values()].sort((a, b) => a.name.localeCompare(b.name) || a.file.localeCompare(b.file));
}

const pageName = (c: Component, all: Component[]) =>
  all.filter((o) => o.name === c.name).length > 1
    ? `${c.name}.${c.file.replace(/\.tsx?$/, "").replace(/[/]/g, "-")}`
    : c.name;

function example(c: Component): string | null {
  const names = new Set(c.props.map((p) => p.name));
  const parsed = c.galleryEntries.flatMap((e) =>
    e.variants.flatMap((v) => {
      if (!v.props || v.props === "{}") return [];
      const fields = [...v.props.matchAll(/(\w+):\s*([^,}]+)/g)].map((m) => [m[1], m[2].trim()] as const);
      return [{ e, v, fields, fits: fields.length > 0 && fields.every(([k]) => names.has(k)) }];
    }),
  );
  const pick = parsed.find((x) => x.fits) ?? parsed[0];
  if (!pick) return null;
  const { e, v, fields, fits } = pick;
  const lines = [
    `Gallery entry \`${e.id}\`, variant \`${v.name}\`${v.note ? `: ${v.note}` : ""}`,
    "",
    "```tsx",
    `// src/${e.file}, variant props: ${v.props}`,
  ];
  if (fits) {
    const attrs = fields.map(([k, val]) =>
      val === "true" ? k : /^["']/.test(val) ? `${k}="${val.slice(1, -1)}"` : `${k}={${val}}`,
    );
    lines.push(`<${c.name} ${attrs.join(" ")} />`);
  }
  lines.push("```");
  return lines.join("\n");
}

function page(c: Component): string {
  const out = [
    `# ${c.name}`,
    "",
    c.summary || "No description yet.",
    "",
    `- File: \`src/${c.file}\``,
    `- Tier: ${c.tier}${c.kitExport && c.tier === "ui" ? " (also exported from the kit barrel `src/kit/index.ts`)" : ""}`,
    `- Status: ${c.status}`,
  ];
  if (c.extends.length) out.push(`- Also accepts: ${c.extends.map((e) => `\`${e}\``).join(", ")}`);
  out.push("", "## Props", "");
  if (c.props.length === 0) out.push("No props declared in the repo.");
  else {
    out.push("| Prop | Type | Required | Description |", "| --- | --- | --- | --- |");
    for (const p of c.props)
      out.push(
        `| \`${p.name}\` | \`${p.type.replace(/\|/g, "\\|")}\` | ${p.optional ? "no" : "yes"} | ${p.doc.replace(/\|/g, "\\|")} |`,
      );
  }
  out.push("", "## Data attributes", "");
  out.push(
    c.dataAttributes.length ? c.dataAttributes.map((a) => `- \`${a}\``).join("\n") : "None set by this component.",
  );
  out.push("", "## Gallery entries", "");
  if (c.galleryEntries.length === 0) out.push("No gallery entry covers this component.");
  for (const e of c.galleryEntries) {
    out.push(
      `- \`${e.id}\` (${e.title}${e.experimental ? ", experimental" : ""}), \`src/${e.file}\`: ${e.variants.map((v) => `\`${v.name}\``).join(", ") || "no variants"}`,
    );
  }
  const ex = example(c);
  if (ex) out.push("", "## Example", "", ex);
  return out.join("\n") + "\n";
}

function render(): Map<string, string> {
  const all = build();
  const files = new Map<string, string>();
  const names = new Map<Component, string>(all.map((c) => [c, pageName(c, all)]));
  files.set(
    MANIFEST,
    JSON.stringify(
      {
        generatedBy: "webviews/scripts/gen-component-manifest.ts",
        galleryPath: GALLERY_PATH,
        components: all.map((c) => ({ ...c, doc: `docs/${names.get(c)}.md` })),
      },
      null,
      2,
    ) + "\n",
  );
  const llms = [
    "# cmux web component library",
    "",
    "> Shared React components for cmux web surfaces: src/ui (primitives) and src/kit (the public base for pages and plugins). Generated by webviews/scripts/gen-component-manifest.ts; machine-readable form: components.generated.json. Compose these instead of hand-rolled views.",
    "",
    "## Components",
    "",
    ...all.map(
      (c) =>
        `- [${c.name}](docs/${names.get(c)}.md): ${c.summary || "No description yet."} (${c.tier}${c.status === "ready" ? "" : `, ${c.status}`})`,
    ),
  ];
  files.set(LLMS, llms.join("\n") + "\n");
  for (const c of all) files.set(join(DOCS, `${names.get(c)}.md`), page(c));
  return files;
}

const files = render();
if (process.argv.includes("--check")) {
  // The outputs are gitignored (no committed generated files), so there is nothing on disk to compare:
  // the check is that the source still generates, and generates the same bytes twice.
  const again = render();
  const problems: string[] = [];
  for (const [f, text] of files) if (again.get(f) !== text) problems.push(`${rel(f)} differs between two runs`);
  if (![...files.keys()].some((f) => f.startsWith(DOCS))) problems.push("no component was found");
  if (problems.length > 0) {
    console.error(`gen-component-manifest: ${problems.join("; ")}`);
    process.exit(1);
  }
  console.log(`gen-component-manifest: ${files.size} files generate, stable`);
} else {
  rmSync(DOCS, { recursive: true, force: true });
  mkdirSync(DOCS, { recursive: true });
  for (const [f, text] of files) writeFileSync(f, text);
  console.log(`gen-component-manifest: wrote ${files.size} files`);
}
