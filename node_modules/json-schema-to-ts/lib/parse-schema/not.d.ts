import { Any, Primitive, Arr, Object, Union, Exclusion } from "../meta-types";
import { IsRepresentable } from "../meta-types/utils";
import { Get, HasKeyIn } from "../utils";
import { ParseSchema } from ".";
import { MergeSubSchema } from "./utils";
declare type AllTypes = Union<Primitive<null> | Primitive<boolean> | Primitive<number> | Primitive<string> | Arr<Any> | Object>;
export declare type ParseNotSchema<S, P = ParseSchema<Omit<S, "not">>, E = Exclusion<HasKeyIn<S, "enum" | "const" | "type" | "anyOf" | "oneOf" | "allOf"> extends true ? P : AllTypes, ParseSchema<MergeSubSchema<Omit<S, "not">, Get<S, "not">>>>> = IsRepresentable<E> extends true ? E : P;
export {};
