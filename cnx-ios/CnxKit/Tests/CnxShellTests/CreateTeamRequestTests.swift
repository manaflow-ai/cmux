import Foundation
import Testing
@testable import CnxAuth

/// Full verify D1 (2026-10-19): Stack refuses team creation from the
/// client, so the phone creates teams through the cmux service.
@Suite struct CreateTeamRequestTests {
    @Test func theRequestGoesToTheServiceWithTheName() throws {
        let request = CnxAuthModel.createTeamRequest(apiBase: URL(string: "https://api.example")!, accessToken: "tok", name: "fv team")
        #expect(request.url?.absoluteString == "https://api.example/v1/teams")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body == ["name": "fv team"])
    }

    @Test func theAnswerIsTheNewTeam() throws {
        let data = Data(#"{"team":{"id":"t-1","name":"fv team"}}"#.utf8)
        let team = try CnxAuthModel.createdTeam(data: data, status: 200)
        #expect(team.id == "t-1")
        #expect(team.name == "fv team")
    }

    @Test func aRefusalIsAnErrorNeverASilentSuccess() {
        let unavailable = Data(#"{"error":{"code":"team_creation_unavailable","message":"x"}}"#.utf8)
        #expect(throws: CnxAuthModel.TeamCreationError.unavailable) { try CnxAuthModel.createdTeam(data: unavailable, status: 503) }
        #expect(throws: CnxAuthModel.TeamCreationError.failed) { try CnxAuthModel.createdTeam(data: Data("{}".utf8), status: 200) }
        #expect(throws: CnxAuthModel.TeamCreationError.failed) { try CnxAuthModel.createdTeam(data: Data(), status: 502) }
    }
}
