import { Get, Head, Tail, Prepend, Reverse, And } from "../../utils";
import { MetaType, Never, Tuple, Error } from "..";
import { Values as ArrValues } from "../array";
import { Values, IsOpen, OpenProps } from "../tuple";
import { IntersectConst } from "./const";
import { IntersectEnum } from "./enum";
import { DistributeIntersection } from "./union";
import { IntersectExclusion } from "./exclusion";
import { ClearIntersections, Intersect } from ".";
export declare type ClearTupleIntersections<T, O = ClearIntersections<OpenProps<T>>> = Tuple<ClearTupleValuesIntersections<Values<T>>, O extends Never ? false : IsOpen<T>, O>;
declare type ClearTupleValuesIntersections<V, R extends any[] = []> = {
    stop: Reverse<R>;
    continue: ClearTupleValuesIntersections<Tail<V>, Prepend<ClearIntersections<Head<V>>, R>>;
}[V extends [any, ...any[]] ? "continue" : "stop"];
export declare type IntersectTuple<A, B> = {
    any: A;
    never: Never;
    const: IntersectConst<B, A>;
    enum: IntersectEnum<B, A>;
    primitive: Never;
    array: IntersectTupleToArray<A, B>;
    tuple: IntersectTuples<A, B>;
    object: Never;
    union: DistributeIntersection<B, A>;
    intersection: Error<"Cannot intersect intersection">;
    exclusion: IntersectExclusion<B, A>;
    error: B;
    errorTypeProperty: Error<"Missing type property">;
}[Get<B, "type"> extends MetaType ? Get<B, "type"> : "errorTypeProperty"];
declare type IntersectTupleToArray<T, A, V = IntersectTupleToArrValues<Values<T>, ArrValues<A>>, N = HasNeverValue<V>, O = Intersect<OpenProps<T>, ArrValues<A>>> = N extends true ? Never : Tuple<V, IsOpen<T> extends true ? (O extends Never ? false : true) : false, O>;
declare type IntersectTupleToArrValues<V, T, R = []> = {
    stop: Reverse<R>;
    continue: R extends any[] ? IntersectTupleToArrValues<Tail<V>, T, Prepend<Intersect<Head<V>, T>, R>> : never;
}[V extends [any, ...any[]] ? "continue" : "stop"];
declare type HasNeverValue<V, R = false> = {
    stop: R;
    continue: Head<V> extends Never ? true : HasNeverValue<Tail<V>>;
}[V extends [any, ...any[]] ? "continue" : "stop"];
declare type IntersectTuples<A, B, V = IntersectTupleValues<Values<A>, Values<B>, IsOpen<A>, IsOpen<B>, OpenProps<A>, OpenProps<B>>, N = HasNeverValue<V>, O = Intersect<OpenProps<A>, OpenProps<B>>> = N extends true ? Never : Tuple<V, O extends Never ? false : And<IsOpen<A>, IsOpen<B>>, O>;
declare type IntersectTupleValues<V1, V2, O1, O2, P1, P2, R extends any[] = []> = {
    stop: Reverse<R>;
    continue1: IntersectTupleValues<Tail<V1>, V2, O1, O2, P1, P2, Prepend<O2 extends true ? Intersect<Head<V1>, P2> : Never, R>>;
    continue2: IntersectTupleValues<V1, Tail<V2>, O1, O2, P1, P2, Prepend<O1 extends true ? Intersect<Head<V2>, P1> : Never, R>>;
    continueBoth: IntersectTupleValues<Tail<V1>, Tail<V2>, O1, O2, P1, P2, Prepend<Intersect<Head<V1>, Head<V2>>, R>>;
}[V1 extends [any, ...any[]] ? V2 extends [any, ...any[]] ? "continueBoth" : "continue1" : V2 extends [any, ...any[]] ? "continue2" : "stop"];
export {};
