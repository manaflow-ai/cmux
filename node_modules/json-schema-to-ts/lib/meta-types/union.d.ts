import { DoesExtend, Get } from "../utils";
import { Resolve } from ".";
import { IsRepresentable } from "./utils";
export declare type UnionType = "union";
export declare type Union<V> = {
    type: UnionType;
    values: V;
};
export declare type Values<U> = Get<U, "values">;
export declare type ResolveUnion<U> = RecurseOnUnion<Values<U>>;
declare type RecurseOnUnion<V> = V extends infer T ? Resolve<T> : never;
export declare type IsUnionRepresentable<U> = DoesExtend<true, AreUnionValuesRepresentable<Values<U>>>;
declare type AreUnionValuesRepresentable<V> = V extends infer T ? IsRepresentable<T> : never;
export {};
