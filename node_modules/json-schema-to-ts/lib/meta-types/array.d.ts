import { Get, Prettify } from "../utils";
import { Resolve, Any } from ".";
export declare type ArrType = "array";
export declare type Arr<V = Any> = {
    type: ArrType;
    values: V;
};
export declare type Values<A> = Get<A, "values">;
export declare type ResolveArr<T> = Prettify<Resolve<Values<T>>[]>;
