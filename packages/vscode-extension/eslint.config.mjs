import js from "@eslint/js";
import tseslint from "typescript-eslint";
import globals from "globals";

export default tseslint.config(
  {
    ignores: [
      "node_modules/**",
      "out/**",
      "dist/**",
      "**/*.d.ts",
    ],
  },
  {
    files: ["**/*.{ts,tsx}"] ,
    extends: [
      js.configs.recommended,
      ...tseslint.configs.recommended,
    ],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      parserOptions: {
        project: false,
      },
      globals: {
        ...globals.node,
      },
    },
    rules: {
      "@typescript-eslint/no-unused-vars": [
        "warn",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
      ],
      "@typescript-eslint/no-explicit-any": "off",
      "curly": "warn",
      "eqeqeq": "warn",
      "no-throw-literal": "warn",
      "@typescript-eslint/naming-convention": [
        "warn",
        {
          selector: "typeLike",
          format: ["PascalCase"],
        },
      ],
      // Use core semi rule; TS variant removed in v8
      "semi": "warn",
      // Avoid noisy refactors for extension code
      "prefer-const": "off",
      // Avoid plugin rule crash differences by forbidding optional chaining short-circuit style
      "no-unused-expressions": ["error", { allowShortCircuit: false, allowTernary: true }],
    },
  }
);

