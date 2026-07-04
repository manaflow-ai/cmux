import Foundation
import SQLite3

// cmux-notif: local macOS Notification Center helper for the cmux inbox.
//
// Reads the system notification store (usernoted db2) so every app's
// delivered notifications become inbox items — no per-app credentials.
// Requires Full Disk Access on the invoking app. Output matches the shared
// cmux helper JSON protocol:
//   cmux-notif status --json
//   cmux-notif recent --json [--cursor <rec_id>]

struct HelperExit: Error {
    let json: [String: Any]
}

func emit(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func notificationDatabasePath() -> String {
    (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
}

func openNotificationDatabase() throws -> OpaquePointer {
    var db: OpaquePointer?
    let rc = sqlite3_open_v2(notificationDatabasePath(), &db, SQLITE_OPEN_READONLY, nil)
    guard rc == SQLITE_OK, let db else {
        if let db { sqlite3_close(db) }
        let denied = rc == SQLITE_CANTOPEN || rc == SQLITE_AUTH || rc == SQLITE_PERM
        throw HelperExit(json: [
            "ok": false,
            "permission_denied": denied,
            "helper_installed": true,
            "message": denied
                ? "Full Disk Access is required to read Notification Center. Grant it to cmux in System Settings > Privacy & Security > Full Disk Access, then quit and reopen cmux."
                : "Unable to open the notification store (sqlite \(rc)).",
        ])
    }
    return db
}

/// Notification dates are seconds since the Apple epoch (2001-01-01).
func unixTime(fromAppleSeconds raw: Double) -> Double {
    raw + 978_307_200.0
}

/// Extracts title/subtitle/body from a record's binary-plist payload.
func parseRecordPayload(_ blob: Data) -> (title: String?, subtitle: String?, body: String?) {
    guard let plist = try? PropertyListSerialization.propertyList(from: blob, format: nil) as? [String: Any] else {
        return (nil, nil, nil)
    }
    let request = (plist["req"] as? [String: Any]) ?? [:]
    return (
        request["titl"] as? String,
        request["subt"] as? String,
        request["body"] as? String
    )
}

func appDisplayName(bundleID: String) -> String {
    // Best-effort prettification without AppKit: use the final bundle
    // component, title-cased ("com.tinyspeck.slackmacgap" -> "Slackmacgap"
    // is worse than "Slack", so prefer known-good tails).
    let tail = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    let known: [String: String] = [
        "slackmacgap": "Slack",
        "MobileSMS": "Messages",
        "mail": "Mail",
        "Discord": "Discord",
        "iCal": "Calendar",
    ]
    return known[tail] ?? tail.prefix(1).uppercased() + tail.dropFirst()
}

/// Bundle ids whose notifications must never loop back into the inbox.
let excludedBundlePrefixes = ["com.cmuxterm.", "com.apple.ScreenTimeNotifications"]

func columnText(_ statement: OpaquePointer?, _ column: Int32) -> String? {
    guard let cString = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: cString)
}

func runStatus() {
    do {
        let db = try openNotificationDatabase()
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(rec_id) FROM record", -1, &statement, nil) == SQLITE_OK else {
            emit(["ok": false, "helper_installed": true, "permission_denied": false,
                  "message": "Notification store schema is unreadable."])
            return
        }
        defer { sqlite3_finalize(statement) }
        _ = sqlite3_step(statement)
        emit(["ok": true, "helper_installed": true, "permission_denied": false,
              "last_sync_at": Date().timeIntervalSince1970])
    } catch let exit as HelperExit {
        emit(exit.json)
    } catch {
        emit(["ok": false, "helper_installed": true, "permission_denied": false,
              "message": "cmux-notif status failed."])
    }
}

func runRecent(cursor: String?) {
    do {
        let db = try openNotificationDatabase()
        defer { sqlite3_close(db) }
        let sinceRecID = Int64(cursor ?? "") ?? 0
        let sql = """
        SELECT r.rec_id, a.identifier, r.data, COALESCE(r.delivered_date, r.request_date)
        FROM record r
        JOIN app a ON a.app_id = r.app_id
        WHERE r.rec_id > ?
        ORDER BY r.rec_id DESC
        LIMIT 200
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HelperExit(json: ["ok": false, "helper_installed": true, "permission_denied": false,
                                    "message": "Notification store query failed."])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sinceRecID)

        var messages: [[String: Any]] = []
        var threads: [String: [String: Any]] = [:]
        var maxRecID = sinceRecID
        while sqlite3_step(statement) == SQLITE_ROW {
            let recID = sqlite3_column_int64(statement, 0)
            maxRecID = max(maxRecID, recID)
            guard let bundleID = columnText(statement, 1) else { continue }
            if excludedBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) { continue }
            guard sqlite3_column_type(statement, 2) == SQLITE_BLOB, let bytes = sqlite3_column_blob(statement, 2) else { continue }
            let blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
            let payload = parseRecordPayload(blob)
            let title = payload.title ?? ""
            let body = payload.body ?? payload.subtitle ?? ""
            guard !title.isEmpty || !body.isEmpty else { continue }
            let timestamp = unixTime(fromAppleSeconds: sqlite3_column_double(statement, 3))
            let appName = appDisplayName(bundleID: bundleID)
            let preview = [title, body].filter { !$0.isEmpty }.joined(separator: " — ")

            messages.append([
                "thread_id": bundleID,
                "message_id": "rec-\(recID)",
                "sender": appName,
                "timestamp": timestamp,
                "preview": String(preview.prefix(200)),
                "body": preview,
                "unread": true,
                "actionable": false,
            ])
            let lastActivity = (threads[bundleID]?["last_activity_at"] as? Double) ?? 0
            if timestamp >= lastActivity {
                threads[bundleID] = [
                    "thread_id": bundleID,
                    "display_name": appName,
                    "last_activity_at": timestamp,
                ]
            }
        }
        emit([
            "ok": true,
            "account_id": "local",
            "threads": Array(threads.values),
            "messages": messages,
            "cursor": String(maxRecID),
        ])
    } catch let exit as HelperExit {
        emit(exit.json)
        Foundation.exit(1)
    } catch {
        emit(["ok": false, "helper_installed": true, "message": "cmux-notif recent failed."])
        Foundation.exit(1)
    }
}

let arguments = CommandLine.arguments.dropFirst()
let command = arguments.first ?? "status"
var cursor: String?
if let index = arguments.firstIndex(of: "--cursor"), arguments.index(after: index) < arguments.endIndex {
    cursor = arguments[arguments.index(after: index)]
}

switch command {
case "status":
    runStatus()
case "recent":
    runRecent(cursor: cursor)
case "send":
    emit(["ok": false, "message": "Notifications are read-only; replies are not supported."])
    Foundation.exit(64)
default:
    emit(["ok": false, "message": "Unknown cmux-notif command: \(command)"])
    Foundation.exit(64)
}
