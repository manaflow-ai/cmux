export declare const functionsSchema: {
    type: string;
    minProperties: number;
    maxProperties: number;
    additionalProperties: boolean;
    patternProperties: {
        '^.{1,256}$': {
            type: string;
            additionalProperties: boolean;
            properties: {
                architecture: {
                    type: string;
                    enum: string[];
                };
                runtime: {
                    type: string;
                    maxLength: number;
                };
                memory: {
                    minimum: number;
                    maximum: number;
                };
                maxDuration: {
                    type: string;
                    minimum: number;
                    maximum: number;
                };
                includeFiles: {
                    type: string;
                    maxLength: number;
                };
                excludeFiles: {
                    type: string;
                    maxLength: number;
                };
                experimentalTriggers: {
                    type: string;
                    items: {
                        type: string;
                        properties: {
                            type: {
                                type: string;
                                const: string;
                            };
                            topic: {
                                type: string;
                                minLength: number;
                            };
                            consumer: {
                                type: string;
                                minLength: number;
                            };
                            maxDeliveries: {
                                type: string;
                                minimum: number;
                            };
                            retryAfterSeconds: {
                                type: string;
                                exclusiveMinimum: number;
                            };
                            initialDelaySeconds: {
                                type: string;
                                minimum: number;
                            };
                            maxConcurrency: {
                                type: string;
                                minimum: number;
                            };
                        };
                        required: string[];
                        additionalProperties: boolean;
                    };
                };
                supportsCancellation: {
                    type: string;
                };
            };
        };
    };
};
export declare const buildsSchema: {
    type: string;
    minItems: number;
    maxItems: number;
    items: {
        type: string;
        additionalProperties: boolean;
        required: string[];
        properties: {
            src: {
                type: string;
                minLength: number;
                maxLength: number;
            };
            use: {
                type: string;
                minLength: number;
                maxLength: number;
            };
            config: {
                type: string;
            };
        };
    };
};
