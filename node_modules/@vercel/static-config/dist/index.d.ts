import { Project } from 'ts-morph';
import { FromSchema, JSONSchema } from 'json-schema-to-ts';
export declare const BaseFunctionConfigSchema: {
    readonly type: "object";
    readonly properties: {
        readonly architecture: {
            readonly type: "string";
            readonly enum: readonly ["x86_64", "arm64"];
        };
        readonly runtime: {
            readonly type: "string";
        };
        readonly memory: {
            readonly type: "number";
        };
        readonly maxDuration: {
            readonly type: "number";
        };
        readonly supportsCancellation: {
            readonly type: "boolean";
        };
        readonly regions: {
            readonly oneOf: readonly [{
                readonly type: "array";
                readonly items: {
                    readonly type: "string";
                };
            }, {
                readonly enum: readonly ["all", "default", "auto"];
            }];
        };
        readonly preferredRegion: {
            readonly oneOf: readonly [{
                readonly type: "string";
            }, {
                readonly type: "array";
                readonly items: {
                    readonly type: "string";
                };
            }];
        };
    };
};
export type BaseFunctionConfig = FromSchema<typeof BaseFunctionConfigSchema>;
export declare function getConfig<T extends JSONSchema = typeof BaseFunctionConfigSchema>(project: Project, sourcePath: string, schema?: T): FromSchema<T> | null;
