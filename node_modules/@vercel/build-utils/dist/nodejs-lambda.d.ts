import { Lambda, LambdaOptionsWithFiles } from './lambda';
interface NodejsLambdaOptions extends LambdaOptionsWithFiles {
    shouldAddHelpers: boolean;
    shouldAddSourcemapSupport: boolean;
    awsLambdaHandler?: string;
    useWebApi?: boolean;
}
export declare class NodejsLambda extends Lambda {
    launcherType: 'Nodejs';
    shouldAddHelpers: boolean;
    shouldAddSourcemapSupport: boolean;
    awsLambdaHandler?: string;
    useWebApi?: boolean;
    constructor({ shouldAddHelpers, shouldAddSourcemapSupport, awsLambdaHandler, useWebApi, ...opts }: NodejsLambdaOptions);
}
export {};
