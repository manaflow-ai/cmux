import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

// The dashboard SPA reads and writes only through the typed oRPC client
// (dashboard-app/lib/rpc.ts), so request and response types come from the
// server procedures. Raw fetch and casts of parsed JSON would bypass that.
const dashboardTypedDataRules = {
  "no-restricted-globals": ["error", {
    name: "fetch",
    message: "Call a dashboard procedure through `dashboardClient` or `rpc` from dashboard-app/lib/rpc.ts.",
  }],
  "no-restricted-syntax": ["error", {
    selector: "TSAsExpression > AwaitExpression > CallExpression[callee.property.name='json']",
    message: "Do not cast response JSON; call a typed dashboard procedure.",
  }, {
    selector: "TSAsExpression > CallExpression[callee.property.name='json']",
    message: "Do not cast response JSON; call a typed dashboard procedure.",
  }, {
    selector: "TSAsExpression > CallExpression[callee.object.name='JSON'][callee.property.name='parse']",
    message: "Do not cast parsed JSON; call a typed dashboard procedure.",
  }],
};

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  {
    files: ["dashboard-app/**/*.{ts,tsx}"],
    ignores: [
      // The RPC link is the one place the dashboard calls fetch.
      "dashboard-app/lib/rpc.ts",
      // Streams the gzip transcript bytes from S3 and decodes them as they
      // arrive; a byte stream is not a typed data call.
      "dashboard-app/screens/vault/transcript-viewer.tsx",
      // Talks to the iroh presence worker on its own origin, not a cmux API.
      "dashboard-app/screens/mobile-devices/**",
    ],
    rules: dashboardTypedDataRules,
  },
  // Override default ignores of eslint-config-next.
  globalIgnores([
    // Default ignores of eslint-config-next:
    ".next/**",
    "out/**",
    "build/**",
    ".pagefind-site/**",
    "public/pagefind/**",
    "next-env.d.ts",
  ]),
]);

export default eslintConfig;
