// Shared `vp check` settings (Oxlint, Oxfmt, type check) for the cmux-next web
// packages. Each package spreads this into its own vite.config.ts so the rules
// and formatting stay identical across webviews/ and cmux-tui/frontends/web/.
// No imports on purpose: this file sits outside every package's node_modules,
// so the packages type it through their own defineConfig.
// `allowWarnings` is for a package whose existing warning backlog has not been
// worked through yet; errors and type errors still fail its check.
// `perfPlugin` is webviews/scripts/lint/perf-footguns.mjs: the performance rules whose cost is
// clear enough to fail (docs/cmux-next/modding-kit.md); the rest of its rules warn only on save.
// Build output is not source; webviews' preview:build writes to dist/.
const BUILD_OUTPUT = ["dist/**"];

type LintPlugin = "eslint" | "typescript" | "unicorn" | "oxc" | "react" | "jsx-a11y" | "import";

export function cmuxCheckConfig({
  fmtIgnorePatterns = [] as string[],
  allowWarnings = false,
  effectCleanupPlugin = undefined as string | undefined,
  perfPlugin = undefined as string | undefined,
  a11yPlugin = undefined as string | undefined,
} = {}) {
  return {
    lint: {
      plugins: ["eslint", "typescript", "unicorn", "oxc", "react", "jsx-a11y", "import"] as LintPlugin[],
      ignorePatterns: BUILD_OUTPUT,
      jsPlugins: [effectCleanupPlugin, perfPlugin, a11yPlugin].filter((plugin): plugin is string => plugin !== undefined),
      // `typeCheck` replaces a separate tsc/tsgo step and needs `typeAware`. The
      // type-aware rules turned off below are new to these packages and stay off
      // until someone works through their findings.
      options: { denyWarnings: !allowWarnings, typeAware: true, typeCheck: true },
      rules: {
        ...(effectCleanupPlugin ? { "cmux-lifecycle/effect-interval-cleanup": "error" as const } : {}),
        ...(perfPlugin
          ? { "cmux-perf/layout-thrash-in-loop": "error" as const, "cmux-perf/no-intl-construct": "error" as const }
          : {}),
        "typescript/await-thenable": "off" as const,
        "typescript/no-base-to-string": "off" as const,
        "typescript/no-redundant-type-constituents": "off" as const,
        "typescript/unbound-method": "off" as const,
        // The built-in rule's role table predates ARIA 1.3, where aria-description is global, and it has no
        // options: a package with the a11y plugin (webviews/scripts/lint/aria-props.mjs) runs the same check with
        // aria-description allowed on every role in its place. Every other package keeps the built-in rule.
        ...(a11yPlugin
          ? {
              "jsx-a11y/role-supports-aria-props": "off" as const,
              "cmux-a11y/role-supports-aria-props": "error" as const,
            }
          : {}),
      },
      // Tests and benches measure layout on purpose; the perf rules are for code that ships.
      overrides: perfPlugin
        ? [
            {
              files: ["test/**", "bench/**", "scripts/**", "**/*.test.ts", "**/*.test.tsx"],
              rules: { "cmux-perf/layout-thrash-in-loop": "off" as const, "cmux-perf/no-intl-construct": "off" as const },
            },
          ]
        : [],
    },
    fmt: {
      printWidth: 120,
      ignorePatterns: [...BUILD_OUTPUT, ...fmtIgnorePatterns],
    },
  };
}
