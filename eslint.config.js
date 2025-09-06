import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import tseslint from 'typescript-eslint'
import { globalIgnores } from 'eslint/config'
import { fileURLToPath } from 'node:url'

const tsconfigRootDir = fileURLToPath(new URL('.', import.meta.url))

export default tseslint.config([
  // Ignore build artifacts across the monorepo
  globalIgnores([
    'dist',
    '**/dist',
    '**/out',
    '**/dist-electron',
    '**/.next',
    '**/build',
    '**/convex/_generated',
  ]),
  {
    files: ['**/*.{ts,tsx}'],
    extends: [
      js.configs.recommended,
      tseslint.configs.recommended,
      reactHooks.configs['recommended-latest'],
      reactRefresh.configs.vite,
    ],
    languageOptions: {
      ecmaVersion: 2020,
      globals: globals.browser,
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
  // Allow Next.js app router files to export metadata and other
  // special exports without tripping react-refresh constraints.
  {
    files: ['apps/*/app/**/*.{ts,tsx}'],
    rules: {
      'react-refresh/only-export-components': 'off',
    },
  },
])
