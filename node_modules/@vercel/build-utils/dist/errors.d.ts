/**
 * This error should be thrown from a Builder in
 * order to stop the build and print a message.
 * This is necessary to avoid printing a stack trace.
 */
export declare class NowBuildError extends Error {
    hideStackTrace: boolean;
    code: string;
    link?: string;
    action?: string;
    constructor({ message, code, link, action }: Props);
}
interface Props {
    /**
     * The error message to display to the end-user.
     * Should be short yet descriptive of what they did wrong.
     */
    message: string;
    /**
     * A unique error code for this particular error.
     * Should start with the builder name such as `NODE_`.
     */
    code: string;
    /**
     * Optional hyperlink starting with https://vercel.com to
     * link to more information about this error.
     */
    link?: string;
    /**
     * Optional "action" to display before the `link`, such as "Learn More".
     */
    action?: string;
}
export declare function getPrettyError(obj: {
    dataPath?: string;
    message?: string;
    params: any;
}): NowBuildError;
export {};
