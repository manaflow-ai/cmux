import Foundation
import Testing
@testable import CmuxAuthRuntime

@Suite struct EmailVerificationRecoveryClientTests {
    @Test func postsNormalizedEmailToRecoveryEndpoint() async throws {
        let client = EmailVerificationRecoveryClient(
            apiBaseURL: "https://cmux.com/",
            load: { request in
                #expect(request.url?.absoluteString == "https://cmux.com/api/auth/email-verification")
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                let body = try #require(request.httpBody)
                let object = try #require(
                    JSONSerialization.jsonObject(with: body) as? [String: String]
                )
                #expect(object == ["email": "buyer@example.com"])
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 202,
                    httpVersion: nil,
                    headerFields: nil
                ))
                return (
                    Data(#"{"ok":true}"#.utf8),
                    response
                )
            }
        )

        try await client.requestVerification(for: " Buyer@Example.com ")
    }

    @Test func mapsRateLimitAndServerFailure() async {
        for (statusCode, expected) in [
            (429, EmailVerificationRecoveryRequestError.rateLimited),
            (503, EmailVerificationRecoveryRequestError.unavailable),
        ] {
            let client = EmailVerificationRecoveryClient(
                apiBaseURL: "https://cmux.com",
                load: { request in
                    (
                        Data(),
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: statusCode,
                            httpVersion: nil,
                            headerFields: nil
                        )!
                    )
                }
            )

            await #expect(throws: expected) {
                try await client.requestVerification(for: "buyer@example.com")
            }
        }
    }

    @Test func postsBillingRecoveryToTheDedicatedEndpoint() async throws {
        let client = EmailVerificationRecoveryClient(
            apiBaseURL: "https://cmux.com",
            load: { request in
                #expect(request.url?.absoluteString == "https://cmux.com/api/billing/recover")
                #expect(request.httpMethod == "POST")
                let body = try #require(request.httpBody)
                let object = try #require(
                    JSONSerialization.jsonObject(with: body) as? [String: String]
                )
                #expect(object == ["email": "billingfixture@gmail.com"])
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 202,
                    httpVersion: nil,
                    headerFields: nil
                ))
                return (Data(#"{"ok":true}"#.utf8), response)
            }
        )

        try await client.requestBillingRecovery(for: " BillingFixture@Gmail.com ")
    }
}
