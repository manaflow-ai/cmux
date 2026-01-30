/**
 * Helper function to support both `VERCEL_` and legacy `NOW_` env vars.
 * Throws an error if *both* env vars are defined.
 */
export declare const getPlatformEnv: (name: string) => string | undefined;
