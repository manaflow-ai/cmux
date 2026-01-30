type Envs = {
    [key: string]: string | undefined;
};
/**
 * Get the framework-specific prefixed System Environment Variables.
 * See https://vercel.com/docs/concepts/projects/environment-variables#system-environment-variables
 * @param envPrefix - Prefix, typically from `@vercel/frameworks`
 * @param envs - Environment Variables, typically from `process.env`
 */
export declare function getPrefixedEnvVars({ envPrefix, envs, }: {
    envPrefix: string | undefined;
    envs: Envs;
}): Envs;
export {};
