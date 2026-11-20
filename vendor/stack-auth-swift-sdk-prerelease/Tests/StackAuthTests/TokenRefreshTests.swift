import Testing
import Foundation
@testable import StackAuth

@Suite("Token Refresh Algorithm Tests")
struct TokenRefreshAlgorithmTests {
    
    // MARK: - JWT Payload Decoding Tests
    
    @Test("Should decode valid JWT payload")
    func decodeValidJwt() {
        // Create a simple JWT with exp and iat claims
        // Header: {"alg":"HS256","typ":"JWT"}
        // Payload: {"exp":9999999999,"iat":1000000000,"sub":"test"}
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let payload = "eyJleHAiOjk5OTk5OTk5OTksImlhdCI6MTAwMDAwMDAwMCwic3ViIjoidGVzdCJ9"
        let signature = "signature"
        let jwt = "\(header).\(payload).\(signature)"
        
        let decoded = decodeJWTPayload(jwt)
        
        #expect(decoded != nil)
        #expect(decoded?.exp == 9999999999)
        #expect(decoded?.iat == 1000000000)
    }
    
    @Test("Should return nil for invalid JWT format")
    func decodeInvalidJwt() {
        let invalid1 = "not-a-jwt"
        let invalid2 = "only.two"
        let invalid3 = ""
        
        #expect(decodeJWTPayload(invalid1) == nil)
        #expect(decodeJWTPayload(invalid2) == nil)
        #expect(decodeJWTPayload(invalid3) == nil)
    }
    
    @Test("Should handle JWT without exp claim")
    func decodeJwtWithoutExp() {
        // Payload: {"iat":1000000000,"sub":"test"} (no exp)
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let payload = "eyJpYXQiOjEwMDAwMDAwMDAsInN1YiI6InRlc3QifQ"
        let signature = "signature"
        let jwt = "\(header).\(payload).\(signature)"
        
        let decoded = decodeJWTPayload(jwt)
        
        #expect(decoded != nil)
        #expect(decoded?.exp == nil)
        #expect(decoded?.expiresInMillis == Int.max) // No exp means never expires
    }
    
    @Test("Should handle JWT without iat claim")
    func decodeJwtWithoutIat() {
        // Payload: {"exp":9999999999,"sub":"test"} (no iat)
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let payload = "eyJleHAiOjk5OTk5OTk5OTksInN1YiI6InRlc3QifQ"
        let signature = "signature"
        let jwt = "\(header).\(payload).\(signature)"
        
        let decoded = decodeJWTPayload(jwt)
        
        #expect(decoded != nil)
        #expect(decoded?.iat == nil)
        #expect(decoded?.issuedMillisAgo == 0) // No iat means issued at epoch
    }
    
    // MARK: - Token Expiration Tests
    
    @Test("Should detect expired token")
    func detectExpiredToken() {
        // Payload with exp in the past (year 2000)
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let payload = "eyJleHAiOjk0NjY4NDgwMCwic3ViIjoidGVzdCJ9" // exp: 946684800 (Jan 1, 2000)
        let signature = "signature"
        let jwt = "\(header).\(payload).\(signature)"
        
        #expect(isTokenExpired(jwt) == true)
    }
    
    @Test("Should detect non-expired token")
    func detectNonExpiredToken() {
        // Payload with exp far in the future (year 2286)
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let payload = "eyJleHAiOjk5OTk5OTk5OTksInN1YiI6InRlc3QifQ" // exp: 9999999999
        let signature = "signature"
        let jwt = "\(header).\(payload).\(signature)"
        
        #expect(isTokenExpired(jwt) == false)
    }
    
    @Test("Should treat nil token as expired")
    func nilTokenIsExpired() {
        #expect(isTokenExpired(nil) == true)
    }
    
    @Test("Should treat invalid token as expired")
    func invalidTokenIsExpired() {
        #expect(isTokenExpired("not-a-jwt") == true)
    }
    
    // MARK: - Token Freshness Tests
    
    @Test("Should consider token with long expiry AND recent issue as fresh")
    func tokenWithLongExpiryAndRecentIssueIsFresh() {
        // Fresh until the token is within the refresh lead of its expiry.
        let now = Int(Date().timeIntervalSince1970)
        let iat = now - 10
        let exp = now + 3600 // Expires in 1 hour, far outside the lead
        
        let payloadJson = "{\"exp\":\(exp),\"iat\":\(iat),\"sub\":\"test\"}"
        let payloadBase64 = Data(payloadJson.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let jwt = "\(header).\(payloadBase64).signature"
        
        #expect(isTokenFreshEnough(jwt) == true)
    }
    
    @Test("Should cap the refresh lead at half a short token lifetime")
    func tokenFreshWhenBothConditionsMet() {
        // 90 s lifetime caps the lead at 45 s; 60 s remain, so still fresh.
        let now = Int(Date().timeIntervalSince1970)
        let iat = now - 30
        let exp = now + 60
        
        // Manually construct JWT payload
        let payloadJson = "{\"exp\":\(exp),\"iat\":\(iat),\"sub\":\"test\"}"
        let payloadBase64 = Data(payloadJson.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let jwt = "\(header).\(payloadBase64).signature"
        
        #expect(isTokenFreshEnough(jwt) == true)
    }
    
    @Test("Should not consider token fresh inside the 20 s floor")
    func tokenNotFreshIfOnlyRecentlyIssued() {
        let now = Int(Date().timeIntervalSince1970)
        let iat = now - 30
        let exp = now + 10 // Expires in 10 seconds, inside the floor
        
        let payloadJson = "{\"exp\":\(exp),\"iat\":\(iat),\"sub\":\"test\"}"
        let payloadBase64 = Data(payloadJson.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let jwt = "\(header).\(payloadBase64).signature"
        
        #expect(isTokenFreshEnough(jwt) == false)
    }
    
    @Test("Should not consider token fresh inside the refresh lead")
    func tokenNotFreshIfOnlyLongExpiry() {
        // The default 60 s lead applies (half the 140 s lifetime is 70 s);
        // only 40 s remain.
        let now = Int(Date().timeIntervalSince1970)
        let iat = now - 100
        let exp = now + 40
        
        let payloadJson = "{\"exp\":\(exp),\"iat\":\(iat),\"sub\":\"test\"}"
        let payloadBase64 = Data(payloadJson.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let jwt = "\(header).\(payloadBase64).signature"
        
        #expect(isTokenFreshEnough(jwt) == false)
    }
    
    @Test("Should consider nil token as not fresh")
    func nilTokenIsNotFresh() {
        #expect(isTokenFreshEnough(nil) == false)
    }
    
    @Test("Should consider invalid token as not fresh")
    func invalidTokenIsNotFresh() {
        #expect(isTokenFreshEnough("not-a-jwt") == false)
    }
    
    // MARK: - Compare And Set Tests
    
    @Test("Should update tokens when refresh token matches")
    func compareAndSetWhenMatching() async {
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "old-access", refreshToken: "original-refresh")
        
        await store.compareAndSet(
            compareRefreshToken: "original-refresh",
            newRefreshToken: "new-refresh",
            newAccessToken: "new-access"
        )
        
        let accessToken = await store.getStoredAccessToken()
        let refreshToken = await store.getStoredRefreshToken()
        
        #expect(accessToken == "new-access")
        #expect(refreshToken == "new-refresh")
    }
    
    @Test("Should not update tokens when refresh token doesn't match")
    func compareAndSetWhenNotMatching() async {
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "old-access", refreshToken: "current-refresh")
        
        // Try to update with wrong compare token
        await store.compareAndSet(
            compareRefreshToken: "wrong-refresh",
            newRefreshToken: "new-refresh",
            newAccessToken: "new-access"
        )
        
        let accessToken = await store.getStoredAccessToken()
        let refreshToken = await store.getStoredRefreshToken()
        
        // Should remain unchanged
        #expect(accessToken == "old-access")
        #expect(refreshToken == "current-refresh")
    }
    
    @Test("Should clear tokens when setting nil")
    func compareAndSetWithNil() async {
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "old-access", refreshToken: "original-refresh")
        
        await store.compareAndSet(
            compareRefreshToken: "original-refresh",
            newRefreshToken: nil,
            newAccessToken: nil
        )
        
        let accessToken = await store.getStoredAccessToken()
        let refreshToken = await store.getStoredRefreshToken()
        
        #expect(accessToken == nil)
        #expect(refreshToken == nil)
    }
    
    // MARK: - Integration Tests with Real Tokens
    
    @Test("Should refresh token and return new access token")
    func refreshTokenIntegration() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let tokensBefore = await app.getAccessToken()
        #expect(tokensBefore != nil)
        
        // Wait a tiny bit to ensure different token if refreshed
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Force fetch a new token
        // Note: This will only actually refresh if the token needs it
        let tokensAfter = await app.getAccessToken()
        #expect(tokensAfter != nil)
        
        // Both should be valid JWTs
        let partsBefore = tokensBefore!.split(separator: ".")
        let partsAfter = tokensAfter!.split(separator: ".")
        #expect(partsBefore.count == 3)
        #expect(partsAfter.count == 3)
    }
    
    @Test("Should return nil when no tokens exist")
    func noTokensReturnsNil() async {
        let app = TestConfig.createClientApp()
        
        // Not signed in, should return nil
        let accessToken = await app.getAccessToken()
        let refreshToken = await app.getRefreshToken()
        
        #expect(accessToken == nil)
        #expect(refreshToken == nil)
    }
    
    @Test("Should handle concurrent getAccessToken calls")
    func concurrentGetAccessToken() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        // Make multiple concurrent calls
        async let token1 = app.getAccessToken()
        async let token2 = app.getAccessToken()
        async let token3 = app.getAccessToken()
        
        let results = await [token1, token2, token3]
        
        // All should return a valid token
        for token in results {
            #expect(token != nil)
            #expect(token!.split(separator: ".").count == 3)
        }
    }
}
