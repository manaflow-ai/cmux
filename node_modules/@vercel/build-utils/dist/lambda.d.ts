/// <reference types="node" />
import type { Config, Env, Files, FunctionFramework, TriggerEvent } from './types';
export type { TriggerEvent };
export type LambdaOptions = LambdaOptionsWithFiles | LambdaOptionsWithZipBuffer;
export type LambdaExecutableRuntimeLanguages = 'rust' | 'go';
export type LambdaArchitecture = 'x86_64' | 'arm64';
export interface LambdaOptionsBase {
    handler: string;
    runtime: string;
    runtimeLanguage?: LambdaExecutableRuntimeLanguages;
    architecture?: LambdaArchitecture;
    memory?: number;
    maxDuration?: number;
    environment?: Env;
    allowQuery?: string[];
    regions?: string[];
    supportsMultiPayloads?: boolean;
    supportsWrapper?: boolean;
    supportsResponseStreaming?: boolean;
    /**
     * @deprecated Use the `supportsResponseStreaming` property instead.
     */
    experimentalResponseStreaming?: boolean;
    operationType?: string;
    framework?: FunctionFramework;
    /**
     * Experimental trigger event definitions that this Lambda can receive.
     * Defines what types of trigger events this Lambda can handle as an HTTP endpoint.
     * Currently supports queue triggers for Vercel's queue system.
     *
     * The delivery configuration provides HINTS to the system about preferred
     * execution behavior (concurrency, retries) but these are NOT guarantees.
     * The system may disregard these hints based on resource constraints.
     *
     * IMPORTANT: HTTP request-response semantics remain synchronous regardless
     * of delivery configuration. Callers receive immediate responses.
     *
     * @experimental This feature is experimental and may change.
     */
    experimentalTriggers?: TriggerEvent[];
    /**
     * Whether this Lambda supports cancellation.
     * When true, the Lambda runtime can be terminated mid-execution if the request is cancelled.
     */
    supportsCancellation?: boolean;
    /**
     * Whether to disable automatic fetch instrumentation.
     * When true, the Function runtime will not automatically instrument fetch calls.
     */
    shouldDisableAutomaticFetchInstrumentation?: boolean;
}
export interface LambdaOptionsWithFiles extends LambdaOptionsBase {
    files: Files;
    experimentalAllowBundling?: boolean;
}
/**
 * @deprecated Use `LambdaOptionsWithFiles` instead.
 */
export interface LambdaOptionsWithZipBuffer extends LambdaOptionsBase {
    /**
     * @deprecated Use `files` property instead.
     */
    zipBuffer: Buffer;
}
interface GetLambdaOptionsFromFunctionOptions {
    sourceFile: string;
    config?: Pick<Config, 'functions'>;
}
export declare class Lambda {
    type: 'Lambda';
    /**
     * This is a label for the type of Lambda a framework is producing.
     * The value can be any string that makes sense for a given framework.
     * Examples: "API", "ISR", "SSR", "SSG", "Render", "Resource"
     */
    operationType?: string;
    files?: Files;
    handler: string;
    runtime: string;
    /**
     * When using a generic runtime such as "executable" or "provided" (custom runtimes),
     * this field can be used to specify the language the executable was compiled with.
     */
    runtimeLanguage?: LambdaExecutableRuntimeLanguages;
    architecture: LambdaArchitecture;
    memory?: number;
    maxDuration?: number;
    environment: Env;
    allowQuery?: string[];
    regions?: string[];
    /**
     * @deprecated Use `await lambda.createZip()` instead.
     */
    zipBuffer?: Buffer;
    supportsMultiPayloads?: boolean;
    supportsWrapper?: boolean;
    supportsResponseStreaming?: boolean;
    framework?: FunctionFramework;
    experimentalAllowBundling?: boolean;
    /**
     * Experimental trigger event definitions that this Lambda can receive.
     * Defines what types of trigger events this Lambda can handle as an HTTP endpoint.
     * Currently supports queue triggers for Vercel's queue system.
     *
     * The delivery configuration provides HINTS to the system about preferred
     * execution behavior (concurrency, retries) but these are NOT guarantees.
     * The system may disregard these hints based on resource constraints.
     *
     * IMPORTANT: HTTP request-response semantics remain synchronous regardless
     * of delivery configuration. Callers receive immediate responses.
     *
     * @experimental This feature is experimental and may change.
     */
    experimentalTriggers?: TriggerEvent[];
    /**
     * Whether this Lambda supports cancellation.
     * When true, the Lambda runtime can be terminated mid-execution if the request is cancelled.
     */
    supportsCancellation?: boolean;
    /**
     * Whether to disable automatic fetch instrumentation.
     * When true, the Function runtime will not automatically instrument fetch calls.
     */
    shouldDisableAutomaticFetchInstrumentation?: boolean;
    constructor(opts: LambdaOptions);
    createZip(): Promise<Buffer>;
    /**
     * @deprecated Use the `supportsResponseStreaming` property instead.
     */
    get experimentalResponseStreaming(): boolean | undefined;
    set experimentalResponseStreaming(v: boolean | undefined);
}
/**
 * @deprecated Use `new Lambda()` instead.
 */
export declare function createLambda(opts: LambdaOptions): Promise<Lambda>;
export declare function createZip(files: Files): Promise<Buffer>;
export declare function getLambdaOptionsFromFunction({ sourceFile, config, }: GetLambdaOptionsFromFunctionOptions): Promise<Pick<LambdaOptions, 'architecture' | 'memory' | 'maxDuration' | 'experimentalTriggers' | 'supportsCancellation'>>;
