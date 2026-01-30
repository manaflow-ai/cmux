import { JSONSchema6Definition, JSONSchema6 } from "json-schema";
import { Replace } from "../utils";
export declare type JSONSchema6DefinitionWithoutInterface = JSONSchema6Definition extends infer S ? S extends JSONSchema6 ? Replace<S, "const" | "enum" | "not", unknown> : S : never;
