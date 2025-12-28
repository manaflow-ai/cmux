import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import tseslint from 'typescript-eslint'
import nextPlugin from '@next/eslint-plugin-next'
import { globalIgnores } from 'eslint/config'
import { fileURLToPath } from 'node:url'

const tsconfigRootDir = fileURLToPath(new URL('.', import.meta.url))

const sharedGlobals = {
  ...globals.es2024,
  ...globals.browser,
  ...globals.node,
}

const typescriptFiles = ['**/*.{ts,tsx}']

const withTypescriptFiles = (config) => ({
  ...config,
  files: typescriptFiles,
})

export default tseslint.config(
  // Global ignores for build artifacts and generated files
  globalIgnores([
    'dist',
    '**/dist',
    '**/out',
    '**/dist-electron',
    '**/.next',
    '**/build',
    'node_modules',
    '**/node_modules',
    // Generated files
    'packages/morphcloud-openapi-client/src/client/**',
    'packages/www-openapi-client/src/client/**',
    'packages/convex/convex/_generated/**',
    // Reference docs (external code, not ours)
    'dev-docs/**',
    // Directories not previously linted (maintain backward compatibility)
    // TODO: Enable linting for these directories and fix errors
    'apps/server/**',
    'apps/worker/**',
    'apps/preview-proxy/**',
    'apps/edge-router/**',
    'apps/global-proxy/**',
    'apps/landing/**',
    'packages/shared/**',
    'packages/convex/**',
    'packages/cmux/**',
    'packages/host-screenshot-collector/**',
    'packages/sandbox/**',
    'packages/sandbox-client/**',
    'scripts/**',
    'evals/**',
    'configs/**',
    'crates/**',
  ]),

  // Base configs for all TypeScript files
  withTypescriptFiles(js.configs.recommended),
  ...tseslint.configs.recommended.map(withTypescriptFiles),
  withTypescriptFiles(reactHooks.configs['recommended-latest']),

  // Base rules
  {
    name: 'cmux/base',
    files: typescriptFiles,
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
      globals: sharedGlobals,
      parserOptions: {
        tsconfigRootDir,
      },
    },
    rules: {
      'react-hooks/exhaustive-deps': 'error',
      '@typescript-eslint/no-unused-vars': [
        'error',
        {
          argsIgnorePattern: '^_',
          varsIgnorePattern: '^_',
          caughtErrorsIgnorePattern: '^_',
        },
      ],
    },
  },

  // Test files
  {
    name: 'cmux/tests',
    files: ['**/*.{test,spec}.{ts,tsx}'],
    languageOptions: {
      globals: {
        ...sharedGlobals,
        ...globals.vitest,
      },
    },
  },

  // Vite apps (apps/client) - react-refresh rules
  {
    name: 'cmux/vite',
    files: ['apps/client/**/*.{ts,tsx}'],
    plugins: {
      'react-refresh': reactRefresh,
    },
    rules: {
      ...reactRefresh.configs.vite.rules,
    },
  },

  // TanStack Router routes - disable react-refresh rule
  // Route files export `Route` (a config object, not a component), so
  // components in these files won't get proper HMR regardless of ESLint config.
  // Per Tanner Linsley: proper HMR requires moving components to separate files.
  {
    name: 'cmux/tanstack-router',
    files: ['apps/client/src/routes/**/*.{ts,tsx}'],
    rules: {
      'react-refresh/only-export-components': 'off',
    },
  },

  // Next.js apps (apps/www)
  {
    name: 'cmux/nextjs',
    files: ['apps/www/**/*.{ts,tsx}'],
    plugins: {
      '@next/next': nextPlugin,
    },
    settings: {
      next: {
        rootDir: 'apps/www',
      },
    },
    rules: {
      ...nextPlugin.configs.recommended.rules,
      ...nextPlugin.configs['core-web-vitals'].rules,
      // Match original www eslint config for backward compat
      'no-irregular-whitespace': 'off',
      'no-useless-catch': 'off',
      'react-hooks/exhaustive-deps': 'warn',
    },
  },

  // Next.js app router - allow metadata, generateStaticParams, etc.
  {
    name: 'cmux/nextjs-app-router',
    files: ['apps/www/app/**/*.{ts,tsx}'],
    rules: {
      'react-refresh/only-export-components': 'off',
    },
  },

  // VSCode extension - no react-refresh needed
  {
    name: 'cmux/vscode-extension',
    files: ['packages/vscode-extension/**/*.{ts,tsx}'],
    rules: {
      'react-refresh/only-export-components': 'off',
    },
  },
)
