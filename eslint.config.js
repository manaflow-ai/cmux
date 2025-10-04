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
    'apps/client/public/vscode',
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
  // Allow Next.js app router files to export metadata and other
  // special exports without tripping react-refresh constraints.
  {
    files: ['apps/*/app/**/*.{ts,tsx}'],
    rules: {
      'react-refresh/only-export-components': 'off',
    },
  },
)
