import { expect, test } from "bun:test";
import { findHoverRevealViolations } from "../scripts/check-popup-hover-reveals";

test("menu-capable hover reveals require the popup-open state", () => {
  const css = `
    .cv-user:hover .cv-user__actions { opacity: 1; }
    .cv-user:has([data-popup-open]) .cv-user__actions { opacity: 1; }
  `;
  expect(findHoverRevealViolations(css)).toEqual([]);
});

test("a missing popup-open selector is a lint error", () => {
  const violations = findHoverRevealViolations(".cv-received:hover .cv-received-actions { opacity: 1; }");
  expect(violations).toHaveLength(1);
  expect(violations[0]?.expected).toBe(".cv-received:has([data-popup-open]) .cv-received-actions");
});

test("new hover-revealed rows are covered without a class allowlist", () => {
  const violations = findHoverRevealViolations(".new-row:hover .new-actions { visibility: visible; }");
  expect(violations).toHaveLength(1);
  expect(violations[0]?.expected).toBe(".new-row:has([data-popup-open]) .new-actions");
});

test("functional hover selectors still require a popup state", () => {
  const css = `
    .new-row:is(:hover,:focus-within) .new-actions { opacity: 1; }
    .new-row:is(:has([data-popup-open]),:focus-within) .new-actions { opacity: 1; }
  `;
  expect(findHoverRevealViolations(css)).toEqual([]);
  expect(findHoverRevealViolations(css.replace("data-popup-open", "aria-expanded=true"))).toHaveLength(1);
});

test("a hidden popup selector does not satisfy the reveal contract", () => {
  const css = `
    .new-row:hover .new-actions { opacity: 1; }
    .new-row:has([data-popup-open]) .new-actions { opacity: 0; }
  `;
  expect(findHoverRevealViolations(css)).toHaveLength(1);
});

test("positive opacity and important visibility/display values are reveals", () => {
  const css = `
    .new-row:hover .new-actions { opacity: .6 !important; visibility: visible !important; }
    .new-row:has([data-popup-open]) .new-actions { opacity: .6; visibility: visible; }
  `;
  expect(findHoverRevealViolations(css)).toEqual([]);
});

test("zero opacity is not a reveal", () => {
  expect(findHoverRevealViolations(".new-row:hover .new-actions { opacity: 0; }")).toEqual([]);
});

test("the popup selector matches the same reveal property and value", () => {
  const css = `
    .new-row:hover .new-actions { opacity: 1; }
    .new-row:has([data-popup-open]) .new-actions { display: flex; }
  `;
  expect(findHoverRevealViolations(css)).toHaveLength(1);
});

test("a popup selector in another media context does not satisfy the reveal", () => {
  const css = `
    .new-row:hover .new-actions { opacity: 1; }
    @media print { .new-row:has([data-popup-open]) .new-actions { opacity: 1; } }
  `;
  expect(findHoverRevealViolations(css)).toHaveLength(1);
});

test("comments cannot hide a missing popup selector", () => {
  const css = `/* .new-row:has([data-popup-open]) .new-actions { opacity: 1; } */\n.new-row:hover .new-actions { opacity: 1; }`;
  expect(findHoverRevealViolations(css)).toHaveLength(1);
});

test("ordinary hover reveals are not treated as popup controls", () => {
  expect(
    findHoverRevealViolations(
      ".cv-table-block:hover .cv-table-tools { opacity: 1; }",
      "agent-session/acpmux/conversation/conversation.css",
    ),
  ).toEqual([]);
});
