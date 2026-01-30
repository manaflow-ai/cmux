import type { Env, Files, FunctionFramework } from './types';
/**
 * An Edge Functions output
 */
export declare class EdgeFunction {
    type: 'EdgeFunction';
    /**
     * A display name for the edge function.
     * @deprecated This property should no longer be used. The name is inferred from the URL path of the function.
     */
    name?: string;
    /**
     * The deployment target.
     * Only `v8-worker` is currently supported.
     */
    deploymentTarget: 'v8-worker';
    /**
     * The entrypoint for the edge function.
     */
    entrypoint: string;
    /**
     * Environment variables for the edge function to use at runtime.
     */
    environment?: Env;
    /**
     * The list of files to be included in the edge function bundle.
     */
    files: Files;
    /**
     * Extra binary files to be included in the edge function
     */
    assets?: {
        name: string;
        path: string;
    }[];
    /** The regions where the edge function will be executed on */
    regions?: string | string[];
    /** The framework */
    framework?: FunctionFramework;
    constructor(params: Omit<EdgeFunction, 'type'>);
}
