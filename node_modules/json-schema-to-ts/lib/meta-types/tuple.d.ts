import { Get, Head, Tail, Prepend, Concat, Reverse } from "../utils";
import { Resolve, Any } from ".";
import { IsRepresentable } from "./utils";
export declare type TupleType = "tuple";
export declare type Tuple<V, O = true, P = Any> = {
    type: TupleType;
    values: V;
    isOpen: O;
    openProps: P;
};
export declare type Values<T> = Get<T, "values">;
export declare type IsOpen<T> = Get<T, "isOpen">;
export declare type OpenProps<T> = Get<T, "openProps">;
export declare type ResolveTuple<T> = IsOpen<T> extends true ? Concat<RecurseOnTuple<Values<T>>, [...Resolve<OpenProps<T>>[]]> : RecurseOnTuple<Values<T>>;
declare type RecurseOnTuple<V, R extends any[] = []> = {
    stop: Reverse<R>;
    continue: V extends any[] ? RecurseOnTuple<Tail<V>, Prepend<Resolve<Head<V>>, R>> : never;
}[V extends [any, ...any[]] ? "continue" : "stop"];
export declare type IsTupleRepresentable<T> = AreAllTupleValuesRepresentable<Values<T>>;
declare type AreAllTupleValuesRepresentable<V> = {
    stop: true;
    continue: V extends any[] ? IsRepresentable<Head<V>> extends false ? false : AreAllTupleValuesRepresentable<Tail<V>> : never;
}[V extends [any, ...any[]] ? "continue" : "stop"];
export {};
