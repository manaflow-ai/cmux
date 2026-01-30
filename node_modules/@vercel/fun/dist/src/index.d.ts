import { Lambda, LambdaParams, InvokeParams, InvokeResult } from './types';
import * as providers from './providers';
import { funCacheDir, runtimes, initializeRuntime } from './runtimes';
export { Lambda, LambdaParams, InvokeParams, InvokeResult, runtimes, providers, funCacheDir, initializeRuntime };
export declare class ValidationError extends Error {
    reserved?: string[];
    constructor(message?: string);
}
export declare function createFunction(params: LambdaParams): Promise<Lambda>;
export declare function invoke(fn: Lambda, params: InvokeParams): Promise<InvokeResult>;
export declare function destroy(fn: Lambda): Promise<void>;
export declare function cleanCacheDir(): Promise<void>;
