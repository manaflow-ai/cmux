import type { PackageJson } from '../types';
export declare function readConfigFile<T>(files: string | string[]): Promise<T | null>;
/**
 * Reads and parses the package.json file from a directory.
 * Returns an empty object if the file doesn't exist or can't be parsed.
 */
export declare function getPackageJson(dir: string): Promise<PackageJson>;
