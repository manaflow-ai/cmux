/**
 * Checks if there is a `.npmrc` in the cwd (project root) and makes sure it
 * doesn't contain a `use-node-version`. This config setting is not supported
 * since it causes the package manager to install the Node.js version which in
 * the case of newer Node.js versions is not compatible with AWS due to
 * outdated GLIBC binaries.
 *
 * @see https://pnpm.io/npmrc#use-node-version
 *
 * @param cwd The current working directory (e.g. project root);
 */
export declare function validateNpmrc(cwd: string): Promise<void>;
