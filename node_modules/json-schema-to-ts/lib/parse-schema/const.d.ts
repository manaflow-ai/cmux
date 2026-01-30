import { Const, Intersection } from "../meta-types";
import { Get, HasKeyIn } from "../utils";
import { ParseSchema } from ".";
export declare type ParseConstSchema<S> = HasKeyIn<S, "type"> extends true ? Intersection<Const<Get<S, "const">>, ParseSchema<Omit<S, "const">>> : Const<Get<S, "const">>;
