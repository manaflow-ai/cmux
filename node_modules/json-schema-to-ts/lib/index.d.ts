import { JSONSchema6Definition } from "json-schema";
import { JSONSchema6DefinitionWithoutInterface } from "./definitions";
import { Resolve } from "./meta-types";
import { ParseSchema } from "./parse-schema";
import { DeepWriteable, DeepReadonly } from "./utils";
/**
 * Unwided JSON schema (e.g. defined with the `as const` statement)
 */
export declare type JSONSchema = JSONSchema6Definition | DeepReadonly<JSONSchema6DefinitionWithoutInterface>;
/**
 * Given a JSON schema defined with the `as const` statement, infers the type of valid instances
 *
 * @param S JSON schema
 */
export declare type FromSchema<S extends JSONSchema> = Resolve<ParseSchema<DeepWriteable<S>>>;
