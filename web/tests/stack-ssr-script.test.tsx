import { describe, expect, mock, test } from "bun:test";
import { fileURLToPath } from "node:url";
import { createElement, type ReactElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

const insertedCallbacks: Array<() => ReactElement | null> = [];

// Next can invoke server-inserted HTML callbacks more than once while a
// request is streamed. Capture the callback so the guard can be exercised
// without starting a Next server.
mock.module("next/navigation", () => ({
  useServerInsertedHTML(callback: () => ReactElement | null) {
    insertedCallbacks.push(callback);
  },
}));

const ssrLayoutEffectPath = fileURLToPath(
  new URL(
    "../node_modules/@stackframe/stack/dist/esm/components/elements/ssr-layout-effect.js",
    import.meta.url,
  ),
);
const { SsrScript } = await import(ssrLayoutEffectPath);

describe("Stack SSR bootstrap script", () => {
  test("inserts one script when streaming invokes the callback twice", () => {
    insertedCallbacks.length = 0;
    const rendered = renderToStaticMarkup(
      createElement(SsrScript, {
        nonce: "test-nonce",
        script: "window.__cmuxTheme = true;",
      }),
    );

    expect(rendered).toBe("");
    expect(insertedCallbacks).toHaveLength(1);

    const callback = insertedCallbacks[0]!;
    const first = callback();
    const second = callback();

    expect(renderToStaticMarkup(first as ReactElement)).toContain(
      'nonce="test-nonce"',
    );
    expect(renderToStaticMarkup(first as ReactElement)).toContain(
      "window.__cmuxTheme = true;",
    );
    expect(second).toBeNull();
  });
});
