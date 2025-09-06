// Minimal typing for import.meta.glob used in tests to avoid depending on Vite
declare interface ImportMeta {
  glob: (
    patterns: string | readonly string[],
    options?: {
      eager?: boolean;
      import?: string;
      as?: string;
      query?: Record<string, string | number | boolean> | string;
    }
  ) => Record<string, () => Promise<unknown>>;
}

