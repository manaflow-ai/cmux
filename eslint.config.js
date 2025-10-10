import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import tseslint from 'typescript-eslint'
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
  // Ignore build artifacts across the monorepo
  globalIgnores([
    'dist',
    '**/dist',
    '**/out',
    '**/dist-electron',
    '**/.next',
    '**/build',
    'node_modules',
    '**/node_modules',
    'apps/client/src/routeTree.gen.ts',
    'packages/www-openapi-client/**',
  ]),
  withTypescriptFiles(js.configs.recommended),
  ...tseslint.configs.recommended.map(withTypescriptFiles),
  withTypescriptFiles(reactHooks.configs['recommended-latest']),
  withTypescriptFiles(reactRefresh.configs.vite),
  {
    name: 'cmux/base',
    files: typescriptFiles,
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
      globals: sharedGlobals,
      parserOptions: {
        // Disambiguate monorepo tsconfig roots (e.g. www-openapi-client)
        tsconfigRootDir,
        projectService: {
          allowDefaultProject: [
            'apps/client/electron-vite-plugin-resolve-workspace.ts',
            'apps/client/electron.vite.config.test.ts',
            'apps/client/electron.vite.config.ts',
            'apps/client/electron/preload/index.d.ts',
            'apps/client/vite.config.ts',
            'apps/client/vitest.config.ts',
          ],
        },
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
      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/no-unnecessary-type-assertion': 'error',
    },
  },
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
  {
    name: 'cmux/client-temp-overrides',
    files: ['apps/client/**/*.{ts,tsx}'],
    rules: {
      '@typescript-eslint/no-unnecessary-type-assertion': 'off',
    },
  },
  // Allow Next.js app router files to export metadata and other
  // special exports without tripping react-refresh constraints.
  {
    files: ['apps/*/app/**/*.{ts,tsx}'],
    rules: {
      'react-refresh/only-export-components': 'off',
    },
  },
)
