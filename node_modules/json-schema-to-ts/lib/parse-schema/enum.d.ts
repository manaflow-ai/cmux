import { Enum, Intersection } from "../meta-types";
import { DeepGet, HasKeyIn } from "../utils";
import { ParseSchema } from ".";
export declare type ParseEnumSchema<S> = HasKeyIn<S, "const" | "type"> extends true ? Intersection<Enum<DeepGet<S, ["enum", number]>>, ParseSchema<Omit<S, "enum">>> : Enum<DeepGet<S, ["enum", number]>>;
