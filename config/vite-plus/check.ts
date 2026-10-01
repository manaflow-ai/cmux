// Shared `vp check` settings (Oxlint, Oxfmt, type check) for the cmux-next web
// packages. Each package spreads this into its own vite.config.ts so the rules
// and formatting stay identical across webviews/ and cmux-tui/frontends/web/.
// No imports on purpose: this file sits outside every package's node_modules,
// so the packages type it through their own defineConfig.
// `allowWarnings` is for a package whose existing warning backlog has not been
// worked through yet; errors and type errors still fail its check.
export function cmuxCheckConfig({ fmtIgnorePatterns = [] as string[], allowWarnings = false } = {}) {
  return {
    lint: {
      plugins: ["eslint", "typescript", "unicorn", "oxc", "react", "jsx-a11y", "import"],
      // `typeCheck` replaces a separate tsc/tsgo step and needs `typeAware`. The
      // type-aware rules turned off below are new to these packages and stay off
      // until someone works through their findings.
      options: { denyWarnings: !allowWarnings, typeAware: true, typeCheck: true },
      rules: {
        "typescript/await-thenable": "off",
        "typescript/no-base-to-string": "off",
        "typescript/no-redundant-type-constituents": "off",
        "typescript/unbound-method": "off",
      },
    },
    fmt: {
      printWidth: 120,
      ignorePatterns: fmtIgnorePatterns,
    },
  };
}
