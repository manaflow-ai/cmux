import Testing
import Foundation
@testable import StackAuth

@Suite("OAuth Tests")
struct OAuthTests {
    
    // Default test URLs (must be absolute URLs)
    let testRedirectUrl = "stack-auth-mobile-oauth-url://success"
    let testErrorRedirectUrl = "stack-auth-mobile-oauth-url://error"
    
    // MARK: - OAuth URL Generation Tests
    
    @Test("Should generate OAuth URL for Google")
    func generateOAuthUrlForGoogle() async throws {
        let app = TestConfig.createClientApp()
        
        let result = try await app.getOAuthUrl(provider: "google", redirectUrl: testRedirectUrl, errorRedirectUrl: testErrorRedirectUrl)
        
        #expect(result.url.absoluteString.contains("oauth/authorize/google"))
        #expect(!result.state.isEmpty)
        #expect(!result.codeVerifier.isEmpty)
    }
    
    @Test("Should generate OAuth URL for GitHub")
    func generateOAuthUrlForGitHub() async throws {
        let app = TestConfig.createClientApp()
        
        let result = try await app.getOAuthUrl(provider: "github", redirectUrl: testRedirectUrl, errorRedirectUrl: testErrorRedirectUrl)
        
        #expect(result.url.absoluteString.contains("oauth/authorize/github"))
        #expect(!result.state.isEmpty)
        #expect(!result.codeVerifier.isEmpty)
    }
    
    @Test("Should generate OAuth URL for Microsoft")
    func generateOAuthUrlForMicrosoft() async throws {
        let app = TestConfig.createClientApp()
        
        let result = try await app.getOAuthUrl(provider: "microsoft", redirectUrl: testRedirectUrl, errorRedirectUrl: testErrorRedirectUrl)
        
        #expect(result.url.absoluteString.contains("oauth/authorize/microsoft"))
        #expect(!result.state.isEmpty)
        #expect(!result.codeVerifier.isEmpty)
    }
    
    @Test("Should include project ID in OAuth URL")
    func oauthUrlIncludesProjectId() async throws {
        let app = TestConfig.createClientApp()
        
        let result = try await app.getOAuthUrl(provider: "google", redirectUrl: testRedirectUrl, errorRedirectUrl: testErrorRedirectUrl)
        
        #expect(result.url.absoluteString.contains("client_id=\(testProjectId)"))
    }
    
    @Test("Should include state in OAuth URL")
    func oauthUrlIncludesState() async throws {
        let app = TestConfig.createClientApp()
        
        let result = try await app.getOAuthUrl(provider: "google", redirectUrl: testRedirectUrl, errorRedirectUrl: testErrorRedirectUrl)
        
        // URL should contain the state parameter
        #expect(result.url.absoluteString.contains("state="))
    }
    
    @Test("Should generate PKCE code verifier")
    func generatesPkceCodeVerifier() async throws {
        let app = TestConfig.createClientApp()
        
        let result = try await app.getOAuthUrl(provider: "google", redirectUrl: testRedirectUrl, errorRedirectUrl: testErrorRedirectUrl)
        
        // Code verifier should be long enough for security (43-128 chars for PKCE)
        #expect(result.codeVerifier.count >= 43)
    }
    
    @Test("Should generate unique state for each call")
    func generatesUniqueState() async throws {
        let app = TestConfig.createClientApp()
        
        let result1 = try await app.getOAuthUrl(provider: "google", redirectUrl: testRedirectUrl, errorRedirectUrl: testErrorRedirectUrl)
        let result2 = try await app.getOAuthUrl(provider: "google", redirectUrl: testRedirectUrl, errorRedirectUrl: testErrorRedirectUrl)
        
        #expect(result1.state != result2.state)
    }
    
    @Test("Should generate unique code verifier for each call")
    func generatesUniqueCodeVerifier() async throws {
        let app = TestConfig.createClientApp()
        
        let result1 = try await app.getOAuthUrl(provider: "google", redirectUrl: testRedirectUrl, errorRedirectUrl: testErrorRedirectUrl)
        let result2 = try await app.getOAuthUrl(provider: "google", redirectUrl: testRedirectUrl, errorRedirectUrl: testErrorRedirectUrl)
        
        #expect(result1.codeVerifier != result2.codeVerifier)
    }
    
    @Test("Should handle case-insensitive provider name")
    func caseInsensitiveProvider() async throws {
        let app = TestConfig.createClientApp()
        
        let result1 = try await app.getOAuthUrl(provider: "Google", redirectUrl: testRedirectUrl, errorRedirectUrl: testErrorRedirectUrl)
        let result2 = try await app.getOAuthUrl(provider: "GOOGLE", redirectUrl: testRedirectUrl, errorRedirectUrl: testErrorRedirectUrl)
        let result3 = try await app.getOAuthUrl(provider: "google", redirectUrl: testRedirectUrl, errorRedirectUrl: testErrorRedirectUrl)
        
        // All should generate valid URLs with google provider
        #expect(result1.url.absoluteString.contains("oauth/authorize/google"))
        #expect(result2.url.absoluteString.contains("oauth/authorize/google"))
        #expect(result3.url.absoluteString.contains("oauth/authorize/google"))
    }
    
    @Test("Should include code challenge in URL")
    func includesCodeChallenge() async throws {
        let app = TestConfig.createClientApp()
        
        let result = try await app.getOAuthUrl(provider: "google", redirectUrl: testRedirectUrl, errorRedirectUrl: testErrorRedirectUrl)
        
        // URL should contain PKCE code challenge
        #expect(result.url.absoluteString.contains("code_challenge="))
        #expect(result.url.absoluteString.contains("code_challenge_method=S256"))
    }
    
    // MARK: - Redirect URL Tests
    // Note: Invalid URL validation (missing scheme) now panics and cannot be tested
    
    @Test("Should return the exact redirect URL provided")
    func returnsExactRedirectUrl() async throws {
        let app = TestConfig.createClientApp()
        
        let result = try await app.getOAuthUrl(provider: "google", redirectUrl: testRedirectUrl, errorRedirectUrl: testErrorRedirectUrl)
        
        #expect(result.redirectUrl == testRedirectUrl)
    }
    
    @Test("Should accept https URLs")
    func acceptsHttpsUrls() async throws {
        let app = TestConfig.createClientApp()
        let httpsUrl = "https://myapp.com/callback"
        let httpsErrorUrl = "https://myapp.com/error"
        
        let result = try await app.getOAuthUrl(provider: "google", redirectUrl: httpsUrl, errorRedirectUrl: httpsErrorUrl)
        
        #expect(result.redirectUrl == httpsUrl)
    }
    
    @Test("Should accept custom scheme URLs")
    func acceptsCustomSchemeUrls() async throws {
        let app = TestConfig.createClientApp()
        let customUrl = "myapp://oauth/callback"
        let customErrorUrl = "myapp://error"
        
        let result = try await app.getOAuthUrl(provider: "google", redirectUrl: customUrl, errorRedirectUrl: customErrorUrl)
        
        #expect(result.redirectUrl == customUrl)
    }

    @Test("Should reject non-HTTPS provider authorization locations")
    func rejectsNonHttpsProviderAuthorizationLocations() throws {
        let providerUrl = try StackClientApp.validatedOAuthProviderAuthorizationUrl(
            from: "https://accounts.google.com/o/oauth2/v2/auth"
        )
        #expect(providerUrl.scheme == "https")

        do {
            _ = try StackClientApp.validatedOAuthProviderAuthorizationUrl(from: "http://accounts.google.com/oauth")
            Issue.record("Expected HTTP provider authorization URL to be rejected")
        } catch let error as OAuthError {
            #expect(error.code == "invalid_url")
        }

        do {
            _ = try StackClientApp.validatedOAuthProviderAuthorizationUrl(from: "not-a-url")
            Issue.record("Expected relative provider authorization URL to be rejected")
        } catch let error as OAuthError {
            #expect(error.code == "invalid_url")
        }

        do {
            _ = try StackClientApp.validatedOAuthProviderAuthorizationUrl(from: "https://accounts.google.com%0d%0aevil.com/")
            Issue.record("Expected control-character provider authorization host to be rejected")
        } catch let error as OAuthError {
            #expect(error.code == "invalid_url")
        }

        do {
            _ = try StackClientApp.validatedOAuthProviderAuthorizationUrl(from: "https://user@example.com/oauth")
            Issue.record("Expected user-info provider authorization URL to be rejected")
        } catch let error as OAuthError {
            #expect(error.code == "invalid_url")
        }

        do {
            _ = try StackClientApp.validatedOAuthProviderAuthorizationUrl(from: "https://accounts.google.com%2fevil.com/oauth")
            Issue.record("Expected encoded host separator in provider authorization URL to be rejected")
        } catch let error as OAuthError {
            #expect(error.code == "invalid_url")
        }

        do {
            _ = try StackClientApp.validatedOAuthProviderAuthorizationUrl(from: "https://accounts.google.com%252fevil.com/oauth")
            Issue.record("Expected double-encoded host separator in provider authorization URL to be rejected")
        } catch let error as OAuthError {
            #expect(error.code == "invalid_url")
        }

        do {
            _ = try StackClientApp.validatedOAuthProviderAuthorizationUrl(from: "https://accounts.google.com%2540evil.com/oauth")
            Issue.record("Expected double-encoded user-info separator in provider authorization URL to be rejected")
        } catch let error as OAuthError {
            #expect(error.code == "invalid_url")
        }
    }
}
