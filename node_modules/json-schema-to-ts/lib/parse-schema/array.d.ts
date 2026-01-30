import { Arr, Tuple, Union, Error } from "../meta-types";
import { Head, Tail, Reverse, DoesExtend, Get, Prepend, IsObject } from "../utils";
import { ParseSchema } from ".";
export declare type ParseArrSchema<S> = "items" extends keyof S ? IsObject<S["items"]> extends true ? Arr<ParseSchema<S["items"]>> : S["items"] extends any[] ? Union<FromTreeTuple<ParseTuple<S["items"]>, S>> : Error<'Invalid value in "items" property'> : Arr;
export declare type ParseTuple<S, R extends any[] = []> = {
    stop: R;
    continue: S extends any[] ? ParseTuple<Tail<S>, Prepend<ParseSchema<Head<S>>, R>> : never;
}[S extends [any, ...any[]] ? "continue" : "stop"];
declare type FromTreeTuple<T, S> = T extends any[] ? ApplyAdditionalItems<ApplyBoundaries<T, "minItems" extends keyof S ? S["minItems"] : 0, "maxItems" extends keyof S ? S["maxItems"] : undefined>, "additionalItems" extends keyof S ? S["additionalItems"] : true> : never;
declare type ApplyBoundaries<T extends any[], Min, Max, R = never, HasMin extends boolean = false, HasMax extends boolean = false, C = T> = {
    stop: {
        result: Max extends undefined ? R | Tuple<Reverse<T>, false> : HasMax extends true ? R | Tuple<Reverse<T>, false> : Max extends T["length"] ? Tuple<Reverse<T>, false> : IsLongerThan<Tail<T>, Max> extends true ? never : R | Tuple<Reverse<T>, false>;
        hasEncounteredMin: DoesExtend<Min, T["length"]>;
        hasEncounteredMax: HasMax extends true ? true : Max extends T["length"] ? true : IsLongerThan<Tail<T>, Max>;
        completeTuple: C;
    };
    continue: ApplyBoundaries<Tail<T>, Min, Max, T["length"] extends Max ? Tuple<Reverse<T>, false> : R | Tuple<Reverse<T>, false>, HasMin extends true ? true : DoesExtend<Min, T["length"]>, HasMax extends true ? true : DoesExtend<Max, T["length"]>, C>;
}[Min extends T["length"] ? "stop" : T extends [any, ...any[]] ? "continue" : "stop"];
declare type IsLongerThan<T extends any[], N, R = false> = {
    continue: T["length"] extends N ? true : IsLongerThan<Tail<T>, N>;
    stop: T["length"] extends N ? true : R;
}[T extends [any, ...any[]] ? "continue" : "stop"];
declare type ApplyAdditionalItems<R, A> = Get<R, "hasEncounteredMax"> extends true ? Get<R, "hasEncounteredMin"> extends true ? Get<R, "result"> : Error<'"minItems" property is lower than "maxItems"'> : A extends false ? Get<R, "hasEncounteredMin"> extends true ? Get<R, "result"> : Error<'"minItems" property is higher than allowed number of items'> : A extends true ? Get<R, "hasEncounteredMin"> extends true ? Get<R, "result"> | Tuple<Reverse<Get<R, "completeTuple">>> : Tuple<Reverse<Get<R, "completeTuple">>> : IsObject<A> extends true ? Get<R, "hasEncounteredMin"> extends true ? Get<R, "result"> | Tuple<Reverse<Get<R, "completeTuple">>, true, ParseSchema<A>> : Tuple<Reverse<Get<R, "completeTuple">>, true, ParseSchema<A>> : Error<'Invalid value in "additionalItems" property'>;
export {};
