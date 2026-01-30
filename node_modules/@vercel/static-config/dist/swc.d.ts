import type { Module } from '@swc/core';
import { FromSchema, JSONSchema } from 'json-schema-to-ts';
export type Value = undefined | null | boolean | string | number | any[] | Record<string, any>;
export declare class UnsupportedValueError extends Error {
}
export declare function extractExportedConstValue(module: Module, exportedName: string): Value | null;
export declare function getConfig<T extends JSONSchema>(module: Module, schema?: T): FromSchema<T> | null;
