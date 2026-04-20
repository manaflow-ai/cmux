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
        // Token must BOTH: expire in >20s AND be issued <75s ago
        let now = Int(Date().timeIntervalSince1970)
        let iat = now - 10 // Issued 10 seconds ago (<75s) ✓
        let exp = now + 3600 // Expires in 1 hour (>20s) ✓
        
        let payloadJson = "{\"exp\":\(exp),\"iat\":\(iat),\"sub\":\"test\"}"
        let payloadBase64 = Data(payloadJson.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let jwt = "\(header).\(payloadBase64).signature"
        
        // Both conditions met, so token is fresh
        #expect(isTokenFreshEnough(jwt) == true)
    }
    
    @Test("Should consider token fresh only when BOTH conditions met")
    func tokenFreshWhenBothConditionsMet() {
        // Token must BOTH: expire in >20s AND be issued <75s ago
        let now = Int(Date().timeIntervalSince1970)
        let iat = now - 30 // Issued 30 seconds ago (<75s) ✓
        let exp = now + 60 // Expires in 60 seconds (>20s) ✓
        
        // Manually construct JWT payload
        let payloadJson = "{\"exp\":\(exp),\"iat\":\(iat),\"sub\":\"test\"}"
        let payloadBase64 = Data(payloadJson.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let jwt = "\(header).\(payloadBase64).signature"
        
        // Both conditions met, so token is fresh
        #expect(isTokenFreshEnough(jwt) == true)
    }
    
    @Test("Should not consider token fresh if only recently issued")
    func tokenNotFreshIfOnlyRecentlyIssued() {
        // Token issued recently but expires soon
        let now = Int(Date().timeIntervalSince1970)
        let iat = now - 30 // Issued 30 seconds ago (<75s) ✓
        let exp = now + 10 // Expires in 10 seconds (<20s) ✗
        
        let payloadJson = "{\"exp\":\(exp),\"iat\":\(iat),\"sub\":\"test\"}"
        let payloadBase64 = Data(payloadJson.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let jwt = "\(header).\(payloadBase64).signature"
        
        // Only one condition met, should refresh
        #expect(isTokenFreshEnough(jwt) == false)
    }
    
    @Test("Should not consider token fresh if only has long expiry")
    func tokenNotFreshIfOnlyLongExpiry() {
        // Token has long expiry but was issued long ago
        let now = Int(Date().timeIntervalSince1970)
        let iat = now - 100 // Issued 100 seconds ago (>75s) ✗
        let exp = now + 60 // Expires in 60 seconds (>20s) ✓
        
        let payloadJson = "{\"exp\":\(exp),\"iat\":\(iat),\"sub\":\"test\"}"
        let payloadBase64 = Data(payloadJson.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let jwt = "\(header).\(payloadBase64).signature"
        
        // Only one condition met, should refresh
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

// MARK: - RefreshLockManager Concurrency Tests

/// Minimal token store for lock testing - we only need an object identity for the lock key
private actor MockTokenStore: TokenStoreProtocol {
    func getStoredAccessToken() async -> String? { nil }
    func getStoredRefreshToken() async -> String? { nil }
    func setTokens(accessToken: String?, refreshToken: String?) async {}
    func clearTokens() async {}
    func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {}
}

@Suite("RefreshLockManager Concurrency Tests")
struct RefreshLockManagerTests {
    
    @Test("Should serialize concurrent lock acquisitions")
    func serializeConcurrentLocks() async {
        let store = MockTokenStore()
        var executionOrder: [Int] = []
        let orderLock = NSLock()
        
        func appendOrder(_ n: Int) {
            orderLock.lock()
            executionOrder.append(n)
            orderLock.unlock()
        }
        
        // Start 3 concurrent tasks that all try to acquire the lock
        await withTaskGroup(of: Void.self) { group in
            for i in 1...3 {
                group.addTask {
                    await RefreshLockManager.shared.acquireLock(for: store)
                    appendOrder(i * 10) // Record entry: 10, 20, or 30
                    // Simulate some work while holding the lock
                    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                    appendOrder(i * 10 + 1) // Record exit: 11, 21, or 31
                    await RefreshLockManager.shared.releaseLock(for: store)
                }
            }
        }
        
        // Verify serialization: each task should complete (entry+exit) before next starts
        // Valid patterns: [10,11,20,21,30,31], [10,11,30,31,20,21], [20,21,10,11,30,31], etc.
        // Invalid: [10,20,11,21,...] - interleaved entries/exits
        
        #expect(executionOrder.count == 6)
        
        // Check that entries and exits are paired (no interleaving)
        var inProgress: Int? = nil
        for event in executionOrder {
            let taskId = event / 10
            let isEntry = event % 10 == 0
            
            if isEntry {
                // Should not have another task in progress when entering
                #expect(inProgress == nil, "Task \(taskId) entered while task \(inProgress ?? -1) was in progress")
                inProgress = taskId
            } else {
                // Should be exiting the same task that entered
                #expect(inProgress == taskId, "Task \(taskId) exited but task \(inProgress ?? -1) was in progress")
                inProgress = nil
            }
        }
    }
    
    @Test("Should allow different stores to lock concurrently")
    func differentStoresCanLockConcurrently() async {
        let store1 = MockTokenStore()
        let store2 = MockTokenStore()
        var concurrentCount = 0
        var maxConcurrent = 0
        let countLock = NSLock()
        
        func incrementConcurrent() {
            countLock.lock()
            concurrentCount += 1
            if concurrentCount > maxConcurrent {
                maxConcurrent = concurrentCount
            }
            countLock.unlock()
        }
        
        func decrementConcurrent() {
            countLock.lock()
            concurrentCount -= 1
            countLock.unlock()
        }
        
        await withTaskGroup(of: Void.self) { group in
            // Task for store1
            group.addTask {
                await RefreshLockManager.shared.acquireLock(for: store1)
                incrementConcurrent()
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                decrementConcurrent()
                await RefreshLockManager.shared.releaseLock(for: store1)
            }
            
            // Task for store2
            group.addTask {
                await RefreshLockManager.shared.acquireLock(for: store2)
                incrementConcurrent()
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                decrementConcurrent()
                await RefreshLockManager.shared.releaseLock(for: store2)
            }
        }
        
        // Both stores should have been able to hold locks concurrently
        #expect(maxConcurrent == 2, "Expected both stores to hold locks concurrently, but max concurrent was \(maxConcurrent)")
    }
    
    @Test("Should handle high contention stress test")
    func stressTestHighContention() async {
        let store = MockTokenStore()
        let taskCount = 50
        var executionOrder: [Int] = []
        let orderLock = NSLock()
        
        func appendOrder(_ n: Int) {
            orderLock.lock()
            executionOrder.append(n)
            orderLock.unlock()
        }
        
        // Launch 50 concurrent tasks all fighting for the same lock
        await withTaskGroup(of: Void.self) { group in
            for i in 1...taskCount {
                group.addTask {
                    await RefreshLockManager.shared.acquireLock(for: store)
                    appendOrder(i * 10) // Entry
                    // Brief work while holding lock
                    try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
                    appendOrder(i * 10 + 1) // Exit
                    await RefreshLockManager.shared.releaseLock(for: store)
                }
            }
        }
        
        // Should have 100 events (50 entries + 50 exits)
        #expect(executionOrder.count == taskCount * 2, "Expected \(taskCount * 2) events, got \(executionOrder.count)")
        
        // Verify serialization - no interleaving under high contention
        var inProgress: Int? = nil
        var interleaveCount = 0
        for event in executionOrder {
            let taskId = event / 10
            let isEntry = event % 10 == 0
            
            if isEntry {
                if inProgress != nil {
                    interleaveCount += 1
                }
                inProgress = taskId
            } else {
                if inProgress != taskId {
                    interleaveCount += 1
                }
                inProgress = nil
            }
        }
        
        #expect(interleaveCount == 0, "Found \(interleaveCount) interleaving violations under high contention - LOCK BUG!")
    }
    
    @Test("Should wake all waiters when lock is released and serialize their acquisition")
    func wakeAllWaitersAndSerialize() async {
        let store = MockTokenStore()
        var executionOrder: [Int] = []
        let orderLock = NSLock()
        
        func appendOrder(_ n: Int) {
            orderLock.lock()
            executionOrder.append(n)
            orderLock.unlock()
        }
        
        // First task acquires lock and holds it
        await RefreshLockManager.shared.acquireLock(for: store)
        
        // Start 3 tasks that will all wait for the lock
        let waitingTasks = Task {
            await withTaskGroup(of: Void.self) { group in
                for i in 1...3 {
                    group.addTask {
                        await RefreshLockManager.shared.acquireLock(for: store)
                        appendOrder(i * 10) // Record entry: 10, 20, or 30
                        // Hold the lock briefly to ensure we'd see interleaving if bug exists
                        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                        appendOrder(i * 10 + 1) // Record exit: 11, 21, or 31
                        await RefreshLockManager.shared.releaseLock(for: store)
                    }
                }
            }
        }
        
        // Give tasks time to start waiting (all 3 should be blocked)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        // Release the lock - all waiters wake up, but only ONE should acquire
        await RefreshLockManager.shared.releaseLock(for: store)
        
        // Wait for all tasks to complete
        await waitingTasks.value
        
        // All 3 waiting tasks should have completed
        #expect(executionOrder.count == 6, "Expected 6 events (3 entries + 3 exits), got \(executionOrder.count)")
        
        // CRITICAL: Verify no interleaving - this catches the while vs if bug
        // If bug exists, multiple waiters acquire lock simultaneously after being resumed
        var inProgress: Int? = nil
        for event in executionOrder {
            let taskId = event / 10
            let isEntry = event % 10 == 0
            
            if isEntry {
                #expect(inProgress == nil, "Task \(taskId) entered while task \(inProgress ?? -1) was in progress - LOCK BUG!")
                inProgress = taskId
            } else {
                #expect(inProgress == taskId, "Task \(taskId) exited but task \(inProgress ?? -1) was in progress")
                inProgress = nil
            }
        }
    }
}
