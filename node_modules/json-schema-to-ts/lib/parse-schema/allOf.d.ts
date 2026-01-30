import { Any, Intersection } from "../meta-types";
import { Tail, Head, Get, HasKeyIn } from "../utils";
import { ParseSchema } from ".";
import { MergeSubSchema } from "./utils";
export declare type ParseAllOfSchema<S> = RecurseOnAllOfSchema<Get<S, "allOf">, S, HasKeyIn<S, "enum" | "const" | "type" | "anyOf" | "oneOf"> extends true ? ParseSchema<Omit<S, "allOf">> : Any>;
declare type RecurseOnAllOfSchema<V, S, R> = {
    stop: R;
    continue: V extends any[] ? RecurseOnAllOfSchema<Tail<V>, S, Intersection<ParseSchema<MergeSubSchema<Omit<S, "allOf">, Head<V>>>, R>> : never;
}[V extends [any, ...any[]] ? "continue" : "stop"];
export {};
