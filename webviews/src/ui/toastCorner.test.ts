import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// RFD 0207 "One toast corner": the toast role's corner is one number, 12, as the native toast's
// (CmuxToastLook). The host-glass arm of experiments.toastGlass draws it; the page arm keeps --role-toast-radius.
const roles = JSON.parse(readFileSync(join(import.meta.dir, "../../../schemas/surface-roles/surface-roles.json"), "utf8"));
const glassCss = readFileSync(join(import.meta.dir, "glass/glass.css"), "utf8");
const noticeCss = readFileSync(join(import.meta.dir, "notice.css"), "utf8");

test("the role file gives the toast one corner, 12, with no stale exception", () => {
  const toast = roles.roles.find((role: { name: string }) => role.name === "toast");
  expect(toast.webRadius).toBe(12);
  expect(roles.exceptions.filter((entry: { role: string }) => entry.role === "toast")).toEqual([]);
  expect(glassCss).toContain("--surface-toast-radius: 12px;");
});

test("a stack toast on the App's toast glass takes the role's corner; the page arm is unchanged", () => {
  expect(noticeCss).toContain('.ui-notice[data-placement="stack"][data-host-glass] {\n  border-radius: var(--surface-toast-radius);');
  expect(noticeCss).toContain("border-radius: var(--role-toast-radius); /* concentric-allow: the toast role caps the concentric corner */");
});
