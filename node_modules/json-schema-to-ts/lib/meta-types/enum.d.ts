import { A, B } from "ts-toolbelt";
import { Get } from "../utils";
export declare type EnumType = "enum";
export declare type Enum<V> = {
    type: EnumType;
    values: V;
};
export declare type Values<E> = Get<E, "values">;
export declare type ResolveEnum<T> = Values<T>;
export declare type IsEnumRepresentable<E> = A.Equals<Values<E>, never> extends B.True ? false : true;
