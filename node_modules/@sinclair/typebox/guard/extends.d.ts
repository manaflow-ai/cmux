import * as Types from '../typebox';
export declare namespace TypeExtends {
    /**
     * This function returns true if the given schema is undefined, either directly or
     * through union composition. This check is required on object property types of
     * undefined, where an additional `'x' in value` check is required to determine
     * the keys existence.
     */
    function Undefined(schema: Types.TSchema): boolean;
}
