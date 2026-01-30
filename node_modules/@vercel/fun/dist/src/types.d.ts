/// <reference types="node" />
/// <reference types="node" />
export interface LambdaParams {
    FunctionName?: string;
    Code: {
        ZipFile?: Buffer | string;
        Directory?: string;
    };
    Handler: string;
    Runtime: string;
    Provider?: string;
    Environment?: {
        Variables: object;
    };
    MemorySize?: number;
    Region?: string;
    AccessKeyId?: string;
    SecretAccessKey?: string;
    Timeout?: number;
}
export type InvokePayload = Buffer | Blob | string;
export interface InvokeParams {
    InvocationType: 'RequestResponse' | 'Event' | 'DryRun';
    Payload?: InvokePayload;
}
export interface InvokeResult {
    StatusCode: number;
    FunctionError?: 'Handled' | 'Unhandled';
    LogResult?: string;
    Payload: InvokePayload;
    ExecutedVersion?: string;
}
export interface Provider {
    invoke(params: InvokeParams): Promise<InvokeResult>;
    destroy(): Promise<void>;
}
export interface Runtime {
    name: string;
    runtimeDir: string;
    cacheDir?: string;
    init?(runtime: Runtime): Promise<void>;
}
export interface Lambda {
    <T>(payload?: string | object): Promise<T>;
    invoke(params: InvokeParams): Promise<InvokeResult>;
    destroy(): Promise<void>;
    params: LambdaParams;
    runtime: Runtime;
    provider: Provider;
    functionName: string;
    memorySize: number;
    version: string;
    region: string;
    arn: string;
    timeout: number;
    extractedDir?: string;
}
