// This entry is bundled as text by artifactRuntimePlugin, never imported/executed by the pane.
import * as React from "react";
import { createRoot } from "react-dom/client";
import { transform } from "sucrase";

const source = (document.getElementById("artifact-source") as HTMLTemplateElement).content.textContent!;
const mount = document.getElementById("artifact-root")!;
const showError = (error: unknown) => {
  const output = document.createElement("pre");
  output.textContent = String(error);
  mount.replaceChildren(output);
};
window.addEventListener("error", (event) => showError(event.message));
try {
  const input = source.trim().startsWith("<") ? `export default () => (${source.trim().replace(/;$/, "")})` : source;
  const code = transform(input, { transforms: ["typescript", "jsx", "imports"], production: true }).code;
  const exports: { default?: React.ComponentType } = {};
  const modules: Record<string, unknown> = { react: React, "react-dom/client": { createRoot } };
  const require = (name: string) => {
    if (Object.hasOwn(modules, name)) return modules[name];
    throw new TypeError(name);
  };
  // Only this opaque frame gets the local module bindings. Generated code stays an inline
  // script here; the parent does not evaluate it and the frame needs no unsafe-eval permission.
  const bindings = {
    React,
    require,
    exports,
    mount: () => {
      if (exports.default) createRoot(mount).render(React.createElement(exports.default));
    },
  };
  Object.assign(globalThis, { __artifact: bindings });
  const script = document.createElement("script");
  script.textContent = `(function(React, require, exports, mount){${code}\n;mount();})(...Object.values(globalThis.__artifact));`;
  document.body.append(script);
} catch (error) {
  showError(error);
}
