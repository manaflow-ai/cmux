/// <reference types="node" />
import { SpawnOptions } from 'child_process';
import { Meta, PackageJson, NodeVersion, Config, BunVersion } from '../types';
export type CliType = 'yarn' | 'npm' | 'pnpm' | 'bun' | 'vlt';
export interface FindPackageJsonResult {
    /**
     * The file path of found `package.json` file, or `undefined` if not found.
     */
    packageJsonPath?: string;
    /**
     * The contents of found `package.json` file, when the `readPackageJson`
     * option is enabled.
     */
    packageJson?: PackageJson;
}
export interface ScanParentDirsResult extends FindPackageJsonResult {
    /**
     * "yarn", "npm", or "pnpm" depending on the presence of lockfiles.
     */
    cliType: CliType;
    /**
     * The file path of the lockfile (`yarn.lock`, `package-lock.json`, or `pnpm-lock.yaml`)
     * or `undefined` if not found.
     */
    lockfilePath?: string;
    /**
     * The `lockfileVersion` number from lockfile (`package-lock.json` or `pnpm-lock.yaml`),
     * or `undefined` if not found.
     */
    lockfileVersion?: number;
    /**
     * The contents of the `packageManager` field from `package.json` if found.
     * The value may come from a different `package.json` file than the one
     * specified by `packageJsonPath`, in the case of a monorepo.
     */
    packageJsonPackageManager?: string;
    /**
     * Whether Turborepo supports the `COREPACK_HOME` environment variable.
     * `undefined` if not a Turborepo project.
     */
    turboSupportsCorepackHome?: boolean;
}
export interface TraverseUpDirectoriesProps {
    /**
     * The directory to start iterating from, typically the same directory of the entrypoint.
     */
    start: string;
    /**
     * The highest directory, typically the workPath root of the project.
     */
    base?: string;
}
export interface WalkParentDirsProps extends Required<TraverseUpDirectoriesProps> {
    /**
     * The name of the file to search for, typically `package.json` or `Gemfile`.
     */
    filename: string;
}
export interface WalkParentDirsMultiProps extends Required<TraverseUpDirectoriesProps> {
    /**
     * The name of the file to search for, typically `package.json` or `Gemfile`.
     */
    filenames: string[];
}
export interface SpawnOptionsExtended extends SpawnOptions {
    /**
     * Pretty formatted command that is being spawned for logging purposes.
     */
    prettyCommand?: string;
    /**
     * Returns instead of throwing an error when the process exits with a
     * non-0 exit code. When relevant, the returned object will include
     * the error code, stdout and stderr.
     */
    ignoreNon0Exit?: boolean;
}
export declare function spawnAsync(command: string, args: string[], opts?: SpawnOptionsExtended): Promise<void>;
export declare function spawnCommand(command: string, options?: SpawnOptions): import("child_process").ChildProcess;
export declare function execCommand(command: string, options?: SpawnOptions): Promise<boolean>;
export declare function traverseUpDirectories({ start, base, }: TraverseUpDirectoriesProps): Generator<string, void, unknown>;
/**
 * @deprecated Use `getNodeBinPaths()` instead.
 */
export declare function getNodeBinPath({ cwd, }: {
    cwd: string;
}): Promise<string>;
export declare function getNodeBinPaths({ start, base, }: TraverseUpDirectoriesProps): string[];
export declare function runShellScript(fsPath: string, args?: string[], spawnOpts?: SpawnOptions): Promise<boolean>;
/**
 * @deprecated Don't use this function directly.
 *
 * Use getEnvForPackageManager() instead when within a builder.
 */
export declare function getSpawnOptions(meta: Meta, nodeVersion: NodeVersion): SpawnOptions;
export declare function getNodeVersion(destPath: string, fallbackVersion?: string | undefined, config?: Config, meta?: Meta, availableVersions?: number[]): Promise<NodeVersion | BunVersion>;
/**
 * Traverses up directories to find and optionally read package.json.
 * This is a lightweight alternative to `scanParentDirs` when only
 * package.json information is needed (without lockfile detection).
 */
export declare function findPackageJson(destPath: string, readPackageJson?: boolean, base?: string): Promise<FindPackageJsonResult>;
export declare function scanParentDirs(destPath: string, readPackageJson?: boolean, base?: string): Promise<ScanParentDirsResult>;
export declare function turboVersionSpecifierSupportsCorepack(turboVersionSpecifier: string): boolean;
export declare function usingCorepack(env: {
    [x: string]: string | undefined;
}, packageJsonPackageManager: string | undefined, turboSupportsCorepackHome: boolean | undefined): boolean;
export declare function walkParentDirs({ base, start, filename, }: WalkParentDirsProps): Promise<string | null>;
/**
 * Reset the customInstallCommandSet. This should be called at the start of each build
 * to prevent custom install commands from being skipped due to the set persisting
 * across multiple builds in the same Node process (e.g., in unit tests).
 */
export declare function resetCustomInstallCommandSet(): void;
export declare function runNpmInstall(destPath: string, args?: string[], spawnOpts?: SpawnOptions, meta?: Meta, projectCreatedAt?: number): Promise<boolean>;
/**
 * Prepares the input environment based on the used package manager and lockfile
 * versions.
 */
export declare function getEnvForPackageManager({ cliType, lockfileVersion, packageJsonPackageManager, env, packageJsonEngines, turboSupportsCorepackHome, projectCreatedAt, }: {
    cliType: CliType;
    lockfileVersion: number | undefined;
    packageJsonPackageManager?: string | undefined;
    env: {
        [x: string]: string | undefined;
    };
    packageJsonEngines?: PackageJson.Engines;
    turboSupportsCorepackHome?: boolean | undefined;
    projectCreatedAt?: number | undefined;
}): {
    [x: string]: string | undefined;
};
export declare const PNPM_10_PREFERRED_AT: Date;
/**
 * Helper to get the binary paths that link to the used package manager.
 * Note: Make sure it doesn't contain any `console.log` calls.
 */
export declare function getPathOverrideForPackageManager({ cliType, lockfileVersion, corepackPackageManager, corepackEnabled, packageJsonEngines, projectCreatedAt, }: {
    cliType: CliType;
    lockfileVersion: number | undefined;
    corepackPackageManager: string | undefined;
    corepackEnabled?: boolean;
    packageJsonEngines?: PackageJson.Engines;
    projectCreatedAt?: number;
}): {
    /**
     * Which lockfile was detected.
     */
    detectedLockfile: string | undefined;
    /**
     * Detected package manager that generated the found lockfile.
     */
    detectedPackageManager: string | undefined;
    /**
     * Value of $PATH that includes the binaries for the detected package manager.
     * Undefined if no $PATH are necessary.
     */
    path: string | undefined;
};
export declare function detectPackageManager(cliType: CliType, lockfileVersion: number | undefined, projectCreatedAt?: number): {
    path: string;
    detectedLockfile: string;
    detectedPackageManager: string;
    pnpmVersionRange: string;
} | {
    path: string;
    detectedLockfile: string;
    detectedPackageManager: string;
    pnpmVersionRange?: undefined;
} | {
    path: undefined;
    detectedLockfile: string;
    detectedPackageManager: string;
    pnpmVersionRange?: undefined;
} | undefined;
/**
 * Helper to get the binary paths that link to the used package manager.
 * Note: Make sure it doesn't contain any `console.log` calls.
 * @deprecated use `getEnvForPackageManager` instead
 */
export declare function getPathForPackageManager({ cliType, lockfileVersion, env, }: {
    cliType: CliType;
    lockfileVersion: number | undefined;
    env: {
        [x: string]: string | undefined;
    };
}): {
    /**
     * Which lockfile was detected.
     */
    detectedLockfile: string | undefined;
    /**
     * Detected package manager that generated the found lockfile.
     */
    detectedPackageManager: string | undefined;
    /**
     * Value of $PATH that includes the binaries for the detected package manager.
     * Undefined if no $PATH are necessary.
     */
    path: string | undefined;
    /**
     * Set if yarn was identified as package manager and `YARN_NODE_LINKER`
     * environment variable was not found on the input environment.
     */
    yarnNodeLinker: string | undefined;
};
export declare function runCustomInstallCommand({ destPath, installCommand, spawnOpts, projectCreatedAt, }: {
    destPath: string;
    installCommand: string;
    spawnOpts?: SpawnOptions;
    projectCreatedAt?: number;
}): Promise<boolean>;
export declare function runPackageJsonScript(destPath: string, scriptNames: string | Iterable<string>, spawnOpts?: SpawnOptions, projectCreatedAt?: number): Promise<boolean>;
export declare function runBundleInstall(destPath: string, args?: string[], spawnOpts?: SpawnOptions, meta?: Meta): Promise<void>;
export type PipInstallResult = {
    installed: false;
} | {
    installed: true;
    /**
     * The directory where packages were installed.
     * Add this to PYTHONPATH when running Python commands.
     */
    targetDir: string;
};
export declare function runPipInstall(destPath: string, args?: string[], spawnOpts?: SpawnOptions, meta?: Meta): Promise<PipInstallResult>;
export declare function getScriptName(pkg: Pick<PackageJson, 'scripts'> | null | undefined, possibleNames: Iterable<string>): string | undefined;
/**
 * @deprecate installDependencies() is deprecated.
 * Please use runNpmInstall() instead.
 */
export declare const installDependencies: typeof runNpmInstall;
