import runtime from "virtual:cmux-artifact-runtime";

/** Preserve source literally; neither JSX strings nor a closing script can escape its container. */
export function jsxDocument(code: string): string {
  const text = code.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return (
    `<div id="artifact-root"></div><template id="artifact-source">${text}</template>` +
    `<script>${runtime.replace(/<\/script/gi, "<\\/script")}</script>`
  );
}
