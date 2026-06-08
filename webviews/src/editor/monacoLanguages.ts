import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";

// Registers syntax highlighting for the common languages. Each per-language
// `*.contribution.js` registers its language id + extensions and a lazy
// `loader: () => import('./<lang>.js')` (Vite splits each grammar into its own
// chunk). The basic-languages `_.contribution.js` only *defines*
// `registerLanguage`; it is not an all-languages aggregate, so importing it
// alone highlights nothing.
//
// JSON has no Monarch grammar, so it uses the JSON language service (its worker
// is wired in `monacoEnvironment`).
import "monaco-editor/esm/vs/basic-languages/bat/bat.contribution.js";
import "monaco-editor/esm/vs/basic-languages/clojure/clojure.contribution.js";
import "monaco-editor/esm/vs/basic-languages/coffee/coffee.contribution.js";
import "monaco-editor/esm/vs/basic-languages/cpp/cpp.contribution.js";
import "monaco-editor/esm/vs/basic-languages/csharp/csharp.contribution.js";
import "monaco-editor/esm/vs/basic-languages/css/css.contribution.js";
import "monaco-editor/esm/vs/basic-languages/dart/dart.contribution.js";
import "monaco-editor/esm/vs/basic-languages/dockerfile/dockerfile.contribution.js";
import "monaco-editor/esm/vs/basic-languages/elixir/elixir.contribution.js";
import "monaco-editor/esm/vs/basic-languages/fsharp/fsharp.contribution.js";
import "monaco-editor/esm/vs/basic-languages/go/go.contribution.js";
import "monaco-editor/esm/vs/basic-languages/graphql/graphql.contribution.js";
import "monaco-editor/esm/vs/basic-languages/handlebars/handlebars.contribution.js";
import "monaco-editor/esm/vs/basic-languages/hcl/hcl.contribution.js";
import "monaco-editor/esm/vs/basic-languages/html/html.contribution.js";
import "monaco-editor/esm/vs/basic-languages/ini/ini.contribution.js";
import "monaco-editor/esm/vs/basic-languages/java/java.contribution.js";
import "monaco-editor/esm/vs/basic-languages/javascript/javascript.contribution.js";
import "monaco-editor/esm/vs/basic-languages/julia/julia.contribution.js";
import "monaco-editor/esm/vs/basic-languages/kotlin/kotlin.contribution.js";
import "monaco-editor/esm/vs/basic-languages/less/less.contribution.js";
import "monaco-editor/esm/vs/basic-languages/lua/lua.contribution.js";
import "monaco-editor/esm/vs/basic-languages/markdown/markdown.contribution.js";
import "monaco-editor/esm/vs/basic-languages/mdx/mdx.contribution.js";
import "monaco-editor/esm/vs/basic-languages/mysql/mysql.contribution.js";
import "monaco-editor/esm/vs/basic-languages/objective-c/objective-c.contribution.js";
import "monaco-editor/esm/vs/basic-languages/perl/perl.contribution.js";
import "monaco-editor/esm/vs/basic-languages/pgsql/pgsql.contribution.js";
import "monaco-editor/esm/vs/basic-languages/php/php.contribution.js";
import "monaco-editor/esm/vs/basic-languages/powershell/powershell.contribution.js";
import "monaco-editor/esm/vs/basic-languages/protobuf/protobuf.contribution.js";
import "monaco-editor/esm/vs/basic-languages/python/python.contribution.js";
import "monaco-editor/esm/vs/basic-languages/r/r.contribution.js";
import "monaco-editor/esm/vs/basic-languages/ruby/ruby.contribution.js";
import "monaco-editor/esm/vs/basic-languages/rust/rust.contribution.js";
import "monaco-editor/esm/vs/basic-languages/scala/scala.contribution.js";
import "monaco-editor/esm/vs/basic-languages/scss/scss.contribution.js";
import "monaco-editor/esm/vs/basic-languages/shell/shell.contribution.js";
import "monaco-editor/esm/vs/basic-languages/solidity/solidity.contribution.js";
import "monaco-editor/esm/vs/basic-languages/sql/sql.contribution.js";
import "monaco-editor/esm/vs/basic-languages/swift/swift.contribution.js";
import "monaco-editor/esm/vs/basic-languages/typescript/typescript.contribution.js";
import "monaco-editor/esm/vs/basic-languages/xml/xml.contribution.js";
import "monaco-editor/esm/vs/basic-languages/yaml/yaml.contribution.js";
import "monaco-editor/esm/vs/language/json/monaco.contribution.js";

/**
 * Grammar modules keyed by Monaco language id. Used to eagerly load a file's
 * Monarch grammar *before* the editor is created. The lazy loaders above tokenize
 * asynchronously after the model exists, and the cmux WKWebView does not always
 * repaint that async re-tokenization (Chrome does), so files could open
 * unhighlighted. Preloading removes the race: the tokenizer is registered before
 * the first render.
 */
const GRAMMARS: Record<string, () => Promise<{ language: unknown; conf?: unknown }>> = {
  bat: () => import("monaco-editor/esm/vs/basic-languages/bat/bat.js"),
  clojure: () => import("monaco-editor/esm/vs/basic-languages/clojure/clojure.js"),
  coffeescript: () => import("monaco-editor/esm/vs/basic-languages/coffee/coffee.js"),
  cpp: () => import("monaco-editor/esm/vs/basic-languages/cpp/cpp.js"),
  csharp: () => import("monaco-editor/esm/vs/basic-languages/csharp/csharp.js"),
  css: () => import("monaco-editor/esm/vs/basic-languages/css/css.js"),
  dart: () => import("monaco-editor/esm/vs/basic-languages/dart/dart.js"),
  dockerfile: () => import("monaco-editor/esm/vs/basic-languages/dockerfile/dockerfile.js"),
  elixir: () => import("monaco-editor/esm/vs/basic-languages/elixir/elixir.js"),
  fsharp: () => import("monaco-editor/esm/vs/basic-languages/fsharp/fsharp.js"),
  go: () => import("monaco-editor/esm/vs/basic-languages/go/go.js"),
  graphql: () => import("monaco-editor/esm/vs/basic-languages/graphql/graphql.js"),
  handlebars: () => import("monaco-editor/esm/vs/basic-languages/handlebars/handlebars.js"),
  hcl: () => import("monaco-editor/esm/vs/basic-languages/hcl/hcl.js"),
  html: () => import("monaco-editor/esm/vs/basic-languages/html/html.js"),
  ini: () => import("monaco-editor/esm/vs/basic-languages/ini/ini.js"),
  java: () => import("monaco-editor/esm/vs/basic-languages/java/java.js"),
  javascript: () => import("monaco-editor/esm/vs/basic-languages/javascript/javascript.js"),
  julia: () => import("monaco-editor/esm/vs/basic-languages/julia/julia.js"),
  kotlin: () => import("monaco-editor/esm/vs/basic-languages/kotlin/kotlin.js"),
  less: () => import("monaco-editor/esm/vs/basic-languages/less/less.js"),
  lua: () => import("monaco-editor/esm/vs/basic-languages/lua/lua.js"),
  markdown: () => import("monaco-editor/esm/vs/basic-languages/markdown/markdown.js"),
  mdx: () => import("monaco-editor/esm/vs/basic-languages/mdx/mdx.js"),
  mysql: () => import("monaco-editor/esm/vs/basic-languages/mysql/mysql.js"),
  "objective-c": () => import("monaco-editor/esm/vs/basic-languages/objective-c/objective-c.js"),
  perl: () => import("monaco-editor/esm/vs/basic-languages/perl/perl.js"),
  pgsql: () => import("monaco-editor/esm/vs/basic-languages/pgsql/pgsql.js"),
  php: () => import("monaco-editor/esm/vs/basic-languages/php/php.js"),
  powershell: () => import("monaco-editor/esm/vs/basic-languages/powershell/powershell.js"),
  "protobuf": () => import("monaco-editor/esm/vs/basic-languages/protobuf/protobuf.js"),
  python: () => import("monaco-editor/esm/vs/basic-languages/python/python.js"),
  r: () => import("monaco-editor/esm/vs/basic-languages/r/r.js"),
  ruby: () => import("monaco-editor/esm/vs/basic-languages/ruby/ruby.js"),
  rust: () => import("monaco-editor/esm/vs/basic-languages/rust/rust.js"),
  scala: () => import("monaco-editor/esm/vs/basic-languages/scala/scala.js"),
  scss: () => import("monaco-editor/esm/vs/basic-languages/scss/scss.js"),
  shell: () => import("monaco-editor/esm/vs/basic-languages/shell/shell.js"),
  sol: () => import("monaco-editor/esm/vs/basic-languages/solidity/solidity.js"),
  sql: () => import("monaco-editor/esm/vs/basic-languages/sql/sql.js"),
  swift: () => import("monaco-editor/esm/vs/basic-languages/swift/swift.js"),
  typescript: () => import("monaco-editor/esm/vs/basic-languages/typescript/typescript.js"),
  xml: () => import("monaco-editor/esm/vs/basic-languages/xml/xml.js"),
  yaml: () => import("monaco-editor/esm/vs/basic-languages/yaml/yaml.js"),
};

/**
 * Eagerly loads and registers the Monarch grammar for the language Monaco infers
 * from `filePath`, so the editor tokenizes synchronously on first render. No-op
 * for JSON (handled by its language service) and any language without a grammar.
 */
export async function preloadGrammarForPath(filePath: string): Promise<void> {
  const dot = filePath.lastIndexOf(".");
  const extension = dot >= 0 ? filePath.slice(dot) : "";
  const probe = monaco.editor.createModel(
    "",
    undefined,
    monaco.Uri.parse(`inmemory://cmux-grammar-probe/probe${extension}`),
  );
  const languageId = probe.getLanguageId();
  probe.dispose();
  const loader = GRAMMARS[languageId];
  if (!loader) {
    return;
  }
  const grammar = await loader();
  monaco.languages.setMonarchTokensProvider(
    languageId,
    grammar.language as monaco.languages.IMonarchLanguage,
  );
  if (grammar.conf) {
    monaco.languages.setLanguageConfiguration(
      languageId,
      grammar.conf as monaco.languages.LanguageConfiguration,
    );
  }
}
