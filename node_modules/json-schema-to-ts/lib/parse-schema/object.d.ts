import { Object, Any, Never, Union, Error } from "../meta-types";
import { IsObject } from "../utils";
import { ParseSchema } from ".";
export declare type ParseObjectSchema<S> = "properties" extends keyof S ? Object<{
    [key in keyof S["properties"]]: ParseSchema<S["properties"][key]>;
}, GetRequired<S>, "additionalProperties" extends keyof S ? S["additionalProperties"] extends false ? false : true : true, GetOpenProps<S>> : Object<{}, GetRequired<S>, true, GetOpenProps<S>>;
declare type GetRequired<S> = S extends {
    required: ReadonlyArray<string>;
} ? S["required"][number] : never;
declare type GetOpenProps<S> = "additionalProperties" extends keyof S ? "patternProperties" extends keyof S ? AdditionalAndPatternProps<S["additionalProperties"], S["patternProperties"]> : AdditionalProps<S["additionalProperties"]> : "patternProperties" extends keyof S ? PatternProps<S["patternProperties"]> : Any;
declare type AdditionalProps<A> = A extends false ? Never : A extends true ? Any : IsObject<A> extends true ? ParseSchema<A> : Error<'Invalid value in "additionalProperties" property'>;
declare type PatternProps<P> = {
    type: "union";
    values: {
        [key in keyof P]: ParseSchema<P[key]>;
    }[keyof P];
};
declare type AdditionalAndPatternProps<A, P> = A extends boolean ? Union<{
    [key in keyof P]: ParseSchema<P[key]>;
}[keyof P]> : IsObject<A> extends true ? Union<ParseSchema<A> | {
    [key in keyof P]: ParseSchema<P[key]>;
}[keyof P]> : never;
export {};
