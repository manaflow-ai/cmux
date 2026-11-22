// Shared `vp check` settings (Oxlint, Oxfmt, type check) for the cmux-next web
// packages. Each package spreads this into its own vite.config.ts so the rules
// and formatting stay identical across webviews/ and cmux-tui/frontends/web/.
// No imports on purpose: this file sits outside every package's node_modules,
// so the packages type it through their own defineConfig.
// `allowWarnings` is for a package whose existing warning backlog has not been
// worked through yet; errors and type errors still fail its check.
// Build output is not source; webviews' preview:build writes to dist/.
const BUILD_OUTPUT = ["dist/**"];

type LintPlugin = "eslint" | "typescript" | "unicorn" | "oxc" | "react" | "jsx-a11y" | "import";

export function cmuxCheckConfig({ fmtIgnorePatterns = [] as string[], allowWarnings = false } = {}) {
  return {
    lint: {
      plugins: ["eslint", "typescript", "unicorn", "oxc", "react", "jsx-a11y", "import"] as LintPlugin[],
      ignorePatterns: BUILD_OUTPUT,
      // `typeCheck` replaces a separate tsc/tsgo step and needs `typeAware`. The
      // type-aware rules turned off below are new to these packages and stay off
      // until someone works through their findings.
      options: { denyWarnings: !allowWarnings, typeAware: true, typeCheck: true },
      rules: {
        "typescript/await-thenable": "off" as const,
        "typescript/no-base-to-string": "off" as const,
        "typescript/no-redundant-type-constituents": "off" as const,
        "typescript/unbound-method": "off" as const,
      },
    },
    fmt: {
      printWidth: 120,
      ignorePatterns: [...BUILD_OUTPUT, ...fmtIgnorePatterns],
    },
  };
}
