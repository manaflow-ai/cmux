import { afterEach, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { setSessionBranch, useSessionBranch } from "./sessionRows";

afterEach(() => setSessionBranch(undefined));

test("a server render reads the session's branch (renderToStaticMarkup throws on a store with no server snapshot)", () => {
  function Probe() {
    return createElement("i", null, useSessionBranch() ?? "none");
  }
  expect(renderToStaticMarkup(createElement(Probe))).toBe("<i>none</i>");
  setSessionBranch("lane/x");
  expect(renderToStaticMarkup(createElement(Probe))).toBe("<i>lane/x</i>");
});
