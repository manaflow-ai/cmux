import { Get } from "../utils";
export declare type ErrorType = "error";
export declare type Error<M = "Unknown error"> = {
    type: ErrorType;
    message: M;
};
export declare type Message<E> = Get<E, "message">;
