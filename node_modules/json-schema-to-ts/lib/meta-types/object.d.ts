import { A, B } from "ts-toolbelt";
import { DoesExtend, Or, Not, Get, DeepMergeUnsafe } from "../utils";
import { Resolve, Any, Never } from ".";
import { IsRepresentable } from "./utils";
export declare type ObjectType = "object";
export declare type Object<V = {}, R = never, O = true, P = Any> = {
    type: ObjectType;
    values: V;
    required: R;
    isOpen: O;
    openProps: P;
};
export declare type Values<O> = Get<O, "values">;
export declare type Value<O, K> = K extends keyof Values<O> ? Values<O>[K] : IsOpen<O> extends true ? OpenProps<O> : Never;
export declare type Required<O> = Get<O, "required"> extends string ? Get<O, "required"> : never;
export declare type IsOpen<O> = Get<O, "isOpen">;
export declare type OpenProps<O> = Get<O, "openProps">;
declare type IsEmpty<O> = DoesExtend<Extract<keyof Values<O>, keyof Values<O>>, never>;
export declare type ResolveObject<O> = IsObjectValid<O> extends true ? ResolveValidObject<O> : never;
declare type IsObjectValid<O> = IsOpen<O> extends false ? Required<O> extends keyof Values<O> ? true : false : true;
declare type ResolveValidObject<O> = DeepMergeUnsafe<IsOpen<O> extends true ? IsEmpty<O> extends true ? {
    [key: string]: Resolve<Get<O, "openProps">>;
} : {
    [key: string]: Resolve<Any>;
} : {}, DeepMergeUnsafe<{
    [key in Exclude<keyof Values<O>, Required<O>>]?: Resolve<Values<O>[key]>;
}, {
    [key in Required<O>]: key extends keyof Values<O> ? Resolve<Values<O>[key]> : Resolve<Any>;
}>>;
declare type IsObjectValueRepresentable<O, K> = K extends keyof Values<O> ? IsRepresentable<Values<O>[K]> : IsOpen<O> extends true ? IsRepresentable<OpenProps<O>> : false;
export declare type IsObjectRepresentable<O> = Or<DoesExtend<A.Equals<Required<O>, never>, B.True>, Not<DoesExtend<false, {
    [key in Required<O>]: IsObjectValueRepresentable<O, key>;
}[Required<O>]>>>;
export {};
