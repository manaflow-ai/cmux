import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const webRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

function source(relativePath) {
  return readFileSync(join(webRoot, relativePath), "utf8");
}

function assertButtonsHaveExplicitTypes(relativePath) {
  const contents = source(relativePath);
  const missingTypes = contents.match(/<button\b(?![^>]*\btype\s*=)[^>]*>/g) ?? [];
  assert.deepEqual(
    missingTypes,
    [],
    `${relativePath} contains button(s) without an explicit type: ${missingTypes.join(" | ")}`,
  );
}

for (const relativePath of [
  "app/[locale]/theme.tsx",
  "app/[locale]/(landing)/docs/docs-nav.tsx",
  "app/[locale]/components/site-header.tsx",
  "app/[locale]/components/spacing-control.tsx",
  "app/[locale]/components/mobile-drawer.tsx",
  "app/[locale]/dashboard/cloud/device-actions.tsx",
  "app/components/pricing-shared.tsx",
]) {
  assertButtonsHaveExplicitTypes(relativePath);
}

const termsPage = source("app/[locale]/(legal)/terms-of-service/page.tsx");
assert.doesNotMatch(
  termsPage,
  /getCurrentYear|new Date\s*\(/,
  "terms copyright must not render a request-time clock value",
);
assert.match(
  termsPage,
  /t\("termsCopyright",\s*\{\s*year:\s*TERMS_COPYRIGHT_YEAR\s*\}\)/,
  "terms copyright must use the localized message with a stable year",
);

const afterSignInHandler = source("app/handler/after-sign-in/handler.ts");
assert.doesNotMatch(
  afterSignInHandler,
  /\.find\s*\(/,
  "after-sign-in lookups must use indexed collections rather than repeated array scans",
);
