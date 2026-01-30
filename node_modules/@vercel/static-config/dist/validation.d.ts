import { FromSchema, JSONSchema } from 'json-schema-to-ts';
export declare function validate<T extends JSONSchema>(schema: T, data: any): FromSchema<T>;
