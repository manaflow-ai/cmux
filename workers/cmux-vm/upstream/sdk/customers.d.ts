import { FreestyleClient } from "./client.js";
/** End-user identity, scoped to your Freestyle account. No billing semantics.
 * Upserts preserve omitted fields; supplied arrays replace previous values.
 */
export interface Customer {
    customerId: string;
    emails?: Array<{
        address: string;
        verified?: boolean;
    }>;
    phoneNumbers?: Array<{
        number: string;
        verified?: boolean;
    }>;
    oauthIdentities?: Array<{
        provider: string;
        subject: string;
    }>;
    githubId?: string;
    ip?: string;
    countryCode?: string;
    /** Unix timestamp in milliseconds. */
    signupDateTime?: number;
}
export declare class CustomersNamespace {
    private readonly client;
    constructor(client: FreestyleClient);
    upsert(customer: Customer): Promise<Customer>;
    get(customerId: string): Promise<Customer>;
}
//# sourceMappingURL=customers.d.ts.map