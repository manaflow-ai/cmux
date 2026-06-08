import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";
// JSON has no Monarch grammar; its language service provides `.json`
// highlighting (its worker is wired in `monacoEnvironment`).
import "monaco-editor/esm/vs/language/json/monaco.contribution.js";

type LanguageDef = {
  id: string;
  extensions: string[];
  grammar: () => Promise<{ language: unknown; conf?: unknown }>;
};

// Common languages registered WITHOUT Monaco's per-language `.contribution.js`
// lazy loaders. The lazy loaders set the Monarch tokens provider via a late
// async `import()` after the model already exists; the cmux WKWebView does not
// reliably repaint that async re-tokenization, so files rendered in a single
// color. Instead we register each language's id + extensions up front (so URI
// inference works) and load its grammar eagerly before the editor is created
// (see `preloadGrammarForPath`), so the tokens provider is the only one set and
// it is in place before the first render.
const LANGUAGES: LanguageDef[] = [
  { id: "bat", extensions: [".bat", ".cmd"], grammar: () => import("monaco-editor/esm/vs/basic-languages/bat/bat.js") },
  { id: "clojure", extensions: [".clj", ".cljs", ".cljc", ".edn"], grammar: () => import("monaco-editor/esm/vs/basic-languages/clojure/clojure.js") },
  { id: "coffeescript", extensions: [".coffee"], grammar: () => import("monaco-editor/esm/vs/basic-languages/coffee/coffee.js") },
  { id: "c", extensions: [".c", ".h"], grammar: () => import("monaco-editor/esm/vs/basic-languages/cpp/cpp.js") },
  { id: "cpp", extensions: [".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx", ".ino"], grammar: () => import("monaco-editor/esm/vs/basic-languages/cpp/cpp.js") },
  { id: "csharp", extensions: [".cs", ".csx", ".cake"], grammar: () => import("monaco-editor/esm/vs/basic-languages/csharp/csharp.js") },
  { id: "css", extensions: [".css"], grammar: () => import("monaco-editor/esm/vs/basic-languages/css/css.js") },
  { id: "dart", extensions: [".dart"], grammar: () => import("monaco-editor/esm/vs/basic-languages/dart/dart.js") },
  { id: "dockerfile", extensions: [".dockerfile"], grammar: () => import("monaco-editor/esm/vs/basic-languages/dockerfile/dockerfile.js") },
  { id: "elixir", extensions: [".ex", ".exs"], grammar: () => import("monaco-editor/esm/vs/basic-languages/elixir/elixir.js") },
  { id: "fsharp", extensions: [".fs", ".fsi", ".fsx", ".fsscript"], grammar: () => import("monaco-editor/esm/vs/basic-languages/fsharp/fsharp.js") },
  { id: "go", extensions: [".go"], grammar: () => import("monaco-editor/esm/vs/basic-languages/go/go.js") },
  { id: "graphql", extensions: [".graphql", ".gql"], grammar: () => import("monaco-editor/esm/vs/basic-languages/graphql/graphql.js") },
  { id: "handlebars", extensions: [".handlebars", ".hbs"], grammar: () => import("monaco-editor/esm/vs/basic-languages/handlebars/handlebars.js") },
  { id: "hcl", extensions: [".tf", ".tfvars", ".hcl"], grammar: () => import("monaco-editor/esm/vs/basic-languages/hcl/hcl.js") },
  { id: "html", extensions: [".html", ".htm", ".shtml", ".xhtml", ".jsp", ".asp", ".aspx", ".jshtm"], grammar: () => import("monaco-editor/esm/vs/basic-languages/html/html.js") },
  { id: "ini", extensions: [".ini", ".properties", ".gitconfig"], grammar: () => import("monaco-editor/esm/vs/basic-languages/ini/ini.js") },
  { id: "java", extensions: [".java", ".jav"], grammar: () => import("monaco-editor/esm/vs/basic-languages/java/java.js") },
  { id: "javascript", extensions: [".js", ".es6", ".jsx", ".mjs", ".cjs"], grammar: () => import("monaco-editor/esm/vs/basic-languages/javascript/javascript.js") },
  { id: "julia", extensions: [".jl"], grammar: () => import("monaco-editor/esm/vs/basic-languages/julia/julia.js") },
  { id: "kotlin", extensions: [".kt", ".kts"], grammar: () => import("monaco-editor/esm/vs/basic-languages/kotlin/kotlin.js") },
  { id: "less", extensions: [".less"], grammar: () => import("monaco-editor/esm/vs/basic-languages/less/less.js") },
  { id: "lua", extensions: [".lua"], grammar: () => import("monaco-editor/esm/vs/basic-languages/lua/lua.js") },
  { id: "markdown", extensions: [".md", ".markdown", ".mdown", ".mkdn", ".mkd", ".mdwn", ".mdtxt", ".mdtext"], grammar: () => import("monaco-editor/esm/vs/basic-languages/markdown/markdown.js") },
  { id: "mdx", extensions: [".mdx"], grammar: () => import("monaco-editor/esm/vs/basic-languages/mdx/mdx.js") },
  { id: "objective-c", extensions: [".m"], grammar: () => import("monaco-editor/esm/vs/basic-languages/objective-c/objective-c.js") },
  { id: "perl", extensions: [".pl", ".pm"], grammar: () => import("monaco-editor/esm/vs/basic-languages/perl/perl.js") },
  { id: "php", extensions: [".php", ".php4", ".php5", ".phtml", ".ctp"], grammar: () => import("monaco-editor/esm/vs/basic-languages/php/php.js") },
  { id: "powershell", extensions: [".ps1", ".psm1", ".psd1"], grammar: () => import("monaco-editor/esm/vs/basic-languages/powershell/powershell.js") },
  { id: "proto", extensions: [".proto"], grammar: () => import("monaco-editor/esm/vs/basic-languages/protobuf/protobuf.js") },
  { id: "python", extensions: [".py", ".rpy", ".pyw", ".cpy", ".gyp", ".gypi"], grammar: () => import("monaco-editor/esm/vs/basic-languages/python/python.js") },
  { id: "r", extensions: [".r", ".rhistory", ".rmd", ".rprofile", ".rt"], grammar: () => import("monaco-editor/esm/vs/basic-languages/r/r.js") },
  { id: "ruby", extensions: [".rb", ".rbx", ".rjs", ".gemspec"], grammar: () => import("monaco-editor/esm/vs/basic-languages/ruby/ruby.js") },
  { id: "rust", extensions: [".rs", ".rlib"], grammar: () => import("monaco-editor/esm/vs/basic-languages/rust/rust.js") },
  { id: "scala", extensions: [".scala", ".sc", ".sbt"], grammar: () => import("monaco-editor/esm/vs/basic-languages/scala/scala.js") },
  { id: "scss", extensions: [".scss"], grammar: () => import("monaco-editor/esm/vs/basic-languages/scss/scss.js") },
  { id: "shell", extensions: [".sh", ".bash"], grammar: () => import("monaco-editor/esm/vs/basic-languages/shell/shell.js") },
  { id: "sol", extensions: [".sol"], grammar: () => import("monaco-editor/esm/vs/basic-languages/solidity/solidity.js") },
  { id: "sql", extensions: [".sql"], grammar: () => import("monaco-editor/esm/vs/basic-languages/sql/sql.js") },
  { id: "swift", extensions: [".swift"], grammar: () => import("monaco-editor/esm/vs/basic-languages/swift/swift.js") },
  { id: "typescript", extensions: [".ts", ".tsx", ".cts", ".mts"], grammar: () => import("monaco-editor/esm/vs/basic-languages/typescript/typescript.js") },
  { id: "xml", extensions: [".xml", ".xsd", ".dtd", ".ascx", ".csproj", ".config", ".props", ".targets", ".plist", ".svg"], grammar: () => import("monaco-editor/esm/vs/basic-languages/xml/xml.js") },
  { id: "yaml", extensions: [".yaml", ".yml"], grammar: () => import("monaco-editor/esm/vs/basic-languages/yaml/yaml.js") },
];

const byExtension = new Map<string, LanguageDef>();
const byId = new Map<string, LanguageDef>();
for (const language of LANGUAGES) {
  monaco.languages.register({ id: language.id, extensions: language.extensions });
  byId.set(language.id, language);
  for (const extension of language.extensions) {
    byExtension.set(extension, language);
  }
}

// Embedded-language grammars tokenize nested code (HTML embeds CSS/JS, Markdown
// embeds fenced code blocks), and their tokenizer references those embedded
// languages by id. If the embedded grammar is not registered, the editor falls
// back to a single token per line. Preload these alongside the host grammar.
const EMBEDDED_LANGUAGES: Record<string, string[]> = {
  html: ["css", "javascript", "typescript"],
  handlebars: ["css", "javascript"],
  php: ["html", "css", "javascript"],
  markdown: ["javascript", "typescript", "python", "java", "go", "rust", "css", "scss", "sql", "yaml", "shell", "ruby", "cpp"],
  mdx: ["javascript", "typescript", "css"],
};

async function loadGrammarById(id: string): Promise<void> {
  const language = byId.get(id);
  if (!language) {
    return;
  }
  const grammar = await language.grammar();
  monaco.languages.setMonarchTokensProvider(
    id,
    grammar.language as monaco.languages.IMonarchLanguage,
  );
  if (grammar.conf) {
    monaco.languages.setLanguageConfiguration(
      id,
      grammar.conf as monaco.languages.LanguageConfiguration,
    );
  }
}

/**
 * Eagerly loads and registers the Monarch grammar for the language matching
 * `filePath`'s extension, so the editor tokenizes synchronously on first render
 * with no later async re-registration. No-op for unmatched extensions and for
 * JSON (handled by its language service).
 */
export async function preloadGrammarForPath(filePath: string): Promise<void> {
  const dot = filePath.lastIndexOf(".");
  if (dot < 0) {
    return;
  }
  const language = byExtension.get(filePath.slice(dot).toLowerCase());
  if (!language) {
    return;
  }
  // Load embedded grammars first so the host grammar's nested tokenizers resolve.
  const embedded = EMBEDDED_LANGUAGES[language.id];
  if (embedded) {
    await Promise.all(embedded.map((id) => loadGrammarById(id)));
  }
  await loadGrammarById(language.id);
}
