import { Merge } from "../utils";
export declare type RemoveInvalidAdditionalItems<S> = "items" extends keyof S ? "additionalItems" extends keyof S ? S : Merge<S, {
    additionalItems: true;
}> : Omit<S, "additionalItems">;
export declare type MergeSubSchema<P, C> = Merge<P, Merge<{
    properties: {};
    additionalProperties: true;
    required: [];
}, RemoveInvalidAdditionalItems<C>>>;
