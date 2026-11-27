import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { WaitSpinner } from "./WaitSpinner";

afterEach(() => {
  delete globalThis.cmuxExperiments;
});

const firstFrame = (until?: boolean) =>
  renderToStaticMarkup(<WaitSpinner size={12} {...(until ? { until: <i data-icon="" /> } : {})} />);

test("at-once (the default) draws the spinner on the first frame", () => {
  expect(firstFrame(true)).toContain("cv-spinner");
  expect(firstFrame(true)).not.toContain("data-icon");
});

test("delayed keeps the control's own icon on the first frame", () => {
  globalThis.cmuxExperiments = { "wait-spinner-delay": "delayed" };
  expect(firstFrame(true)).toContain("data-icon");
  expect(firstFrame(true)).not.toContain('cv-spinner"');
});

test("delayed with no icon holds an empty box the spinner's size, so nothing moves", () => {
  globalThis.cmuxExperiments = { "wait-spinner-delay": "delayed" };
  const html = firstFrame();
  expect(html).toContain("data-spinner-wait");
  expect(html).toContain("width:12px");
});
