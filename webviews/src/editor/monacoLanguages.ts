// Registers syntax highlighting for the common languages. Each per-language
// `*.contribution.js` registers its language id + extensions and a lazy
// `loader: () => import('./<lang>.js')` that Vite splits into its own chunk and
// loads on demand the first time a file of that language is opened. (The
// basic-languages `_.contribution.js` only *defines* `registerLanguage`; it is
// not an all-languages aggregate, so importing it alone highlights nothing.)
//
// JSON is the one common language with no Monarch grammar, so it uses the JSON
// language service (its worker is wired in `monacoEnvironment`).
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
