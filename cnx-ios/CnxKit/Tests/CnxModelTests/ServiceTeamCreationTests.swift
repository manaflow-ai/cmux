import Foundation
import Testing
@testable import CnxModel

/// Full verify D1 (2026-10-19): Stack refuses team creation from the
/// client, so the phone creates teams through the cmux service.
@Suite struct ServiceTeamCreationTests {
    let creation = ServiceTeamCreation(apiBase: URL(string: "https://api.example")!)

    @Test func theRequestGoesToTheServiceWithTheName() throws {
        let request = creation.request(accessToken: "tok", name: "fv team")
        #expect(request.url?.absoluteString == "https://api.example/v1/teams")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body == ["name": "fv team"])
    }

    @Test func theAnswerIsTheNewTeam() throws {
        let team = try creation.team(from: Data(#"{"team":{"id":"t-1","name":"fv team"}}"#.utf8), status: 200)
        #expect(team.id == "t-1")
        #expect(team.name == "fv team")
    }

    @Test func aRefusalIsAnErrorNeverASilentSuccess() {
        let unavailable = Data(#"{"error":{"code":"team_creation_unavailable","message":"x"}}"#.utf8)
        #expect(throws: ServiceTeamCreation.Failure.unavailable) { try creation.team(from: unavailable, status: 503) }
        #expect(throws: ServiceTeamCreation.Failure.failed) { try creation.team(from: Data("{}".utf8), status: 200) }
        #expect(throws: ServiceTeamCreation.Failure.failed) { try creation.team(from: Data(), status: 502) }
    }
}
