import Foundation
import SQLite3

// cmux-imsg: local iMessage helper for the cmux inbox.
//
// Reads ~/Library/Messages/chat.db directly (requires Full Disk Access on the
// invoking app) and sends replies through Messages.app scripting. All output
// is single-object JSON on stdout, matching IMessageHelperJSONAdapter:
//   cmux-imsg status --json
//   cmux-imsg recent --json [--cursor <rowid>]
//   cmux-imsg send --json   (stdin: {"thread_id": <chat guid>, "body": <text>})

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct HelperExit: Error {
    let json: [String: Any]
}

func emit(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func chatDatabasePath() -> String {
    (NSHomeDirectory() as NSString).appendingPathComponent("Library/Messages/chat.db")
}

func openChatDatabase() throws -> OpaquePointer {
    var db: OpaquePointer?
    // Read-only; never mutate the Messages store.
    let rc = sqlite3_open_v2(chatDatabasePath(), &db, SQLITE_OPEN_READONLY, nil)
    guard rc == SQLITE_OK, let db else {
        if let db { sqlite3_close(db) }
        let denied = rc == SQLITE_CANTOPEN || rc == SQLITE_AUTH || rc == SQLITE_PERM
        throw HelperExit(json: [
            "ok": false,
            "permission_denied": denied,
            "helper_installed": true,
            "message": denied
                ? "Full Disk Access is required to read Messages. Grant it to cmux in System Settings > Privacy & Security > Full Disk Access, then quit and reopen cmux."
                : "Unable to open the Messages database (sqlite \(rc)).",
        ])
    }
    return db
}

/// Messages stores dates as nanoseconds since 2001-01-01 on modern macOS and
/// seconds on very old databases; both convert to the Unix epoch here.
func unixTime(fromAppleDate raw: Int64) -> Double {
    let appleEpochOffset = 978_307_200.0
    if raw > 100_000_000_000 { return Double(raw) / 1_000_000_000 + appleEpochOffset }
    return Double(raw) + appleEpochOffset
}

/// Extracts readable text from a typedstream-archived attributedBody blob.
/// Modern macOS leaves message.text NULL for many messages and stores the
/// string inside this legacy archive; the payload string follows the first
/// "NSString" class marker: 0x2B ('+') then a one-byte length, or 0x81 plus a
/// two-byte little-endian length for longer strings.
func textFromAttributedBody(_ blob: Data) -> String? {
    guard let marker = blob.range(of: Data("NSString".utf8)) else { return nil }
    var index = marker.upperBound
    while index < blob.count, blob[index] != 0x2B {
        index += 1
        if index - marker.upperBound > 24 { return nil }
    }
    index += 1
    guard index < blob.count else { return nil }
    var length = 0
    if blob[index] == 0x81 {
        guard index + 2 < blob.count else { return nil }
        length = Int(blob[index + 1]) | (Int(blob[index + 2]) << 8)
        index += 3
    } else {
        length = Int(blob[index])
        index += 1
    }
    guard length > 0, index + length <= blob.count else { return nil }
    return String(data: blob.subdata(in: index..<(index + length)), encoding: .utf8)
}

func columnText(_ statement: OpaquePointer?, _ column: Int32) -> String? {
    guard let cString = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: cString)
}

func runStatus() {
    do {
        let db = try openChatDatabase()
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        // A prepared read proves both file access and a sane schema.
        guard sqlite3_prepare_v2(db, "SELECT MAX(ROWID) FROM message", -1, &statement, nil) == SQLITE_OK else {
            emit(["ok": false, "helper_installed": true, "permission_denied": false,
                  "message": "Messages database schema is unreadable."])
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
              "message": "cmux-imsg status failed."])
    }
}

// Recent pages ascending from the cursor so a burst larger than the page
// limit continues on the next sync instead of skipping rows the max-ROWID
// cursor would otherwise jump past.
func runRecent(cursor: String?) {
    do {
        let db = try openChatDatabase()
        defer { sqlite3_close(db) }
        let sinceROWID = Int64(cursor ?? "") ?? 0
        let sql = """
        SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.is_from_me, m.is_read,
               c.guid, COALESCE(NULLIF(c.display_name, ''), c.chat_identifier), COALESCE(h.id, '')
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE m.ROWID > ? AND m.associated_message_type = 0 AND m.item_type = 0
        ORDER BY m.ROWID ASC
        LIMIT 200
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HelperExit(json: ["ok": false, "helper_installed": true, "permission_denied": false,
                                    "message": "Messages database query failed."])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sinceROWID)

        var messages: [[String: Any]] = []
        var threads: [String: [String: Any]] = [:]
        var maxROWID = sinceROWID
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(statement, 0)
            maxROWID = max(maxROWID, rowID)
            let messageGUID = columnText(statement, 1) ?? "rowid-\(rowID)"
            var body = columnText(statement, 2)
            if body == nil || body?.isEmpty == true, sqlite3_column_type(statement, 3) == SQLITE_BLOB,
               let bytes = sqlite3_column_blob(statement, 3) {
                let blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 3)))
                body = textFromAttributedBody(blob)
            }
            guard let text = body, !text.isEmpty else { continue }
            let timestamp = unixTime(fromAppleDate: sqlite3_column_int64(statement, 4))
            let isFromMe = sqlite3_column_int(statement, 5) == 1
            let isRead = sqlite3_column_int(statement, 6) == 1
            guard let chatGUID = columnText(statement, 7) else { continue }
            let chatName = columnText(statement, 8) ?? "Messages"
            let handle = columnText(statement, 9) ?? ""
            let sender = isFromMe ? "Me" : (handle.isEmpty ? chatName : handle)

            messages.append([
                "thread_id": chatGUID,
                "message_id": messageGUID,
                "sender": sender,
                "timestamp": timestamp,
                "preview": String(text.prefix(160)),
                "body": text,
                "unread": !isFromMe && !isRead,
                "actionable": false,
            ])
            let lastActivity = (threads[chatGUID]?["last_activity_at"] as? Double) ?? 0
            if timestamp >= lastActivity {
                threads[chatGUID] = [
                    "thread_id": chatGUID,
                    "display_name": chatName,
                    "last_activity_at": timestamp,
                ]
            }
        }
        emit([
            "ok": true,
            "account_id": "local",
            "threads": Array(threads.values),
            "messages": messages,
            "cursor": String(maxROWID),
        ])
    } catch let exit as HelperExit {
        emit(exit.json)
        Foundation.exit(1)
    } catch {
        emit(["ok": false, "helper_installed": true, "message": "cmux-imsg recent failed."])
        Foundation.exit(1)
    }
}

func runSend() {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
          let chatGUID = object["thread_id"] as? String, !chatGUID.isEmpty,
          let body = object["body"] as? String, !body.isEmpty else {
        emit(["ok": false, "message": "send requires JSON stdin with thread_id and body"])
        Foundation.exit(64)
    }
    // Messages.app performs the actual send, so delivery uses the user's real
    // signed-in account and shows up in the conversation like any other reply.
    func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    let script = "tell application \"Messages\" to send \"\(escaped(body))\" to chat id \"\(escaped(chatGUID))\""
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    do {
        try process.run()
        // Drain stderr before waiting: reading after exit deadlocks once the
        // pipe buffer fills (same class as the app-side helper runner fix).
        let errorOutput = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            emit(["ok": false, "message": "Messages send failed: \(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))"])
            Foundation.exit(1)
        }
        emit(["ok": true])
    } catch {
        emit(["ok": false, "message": "Unable to run osascript for Messages send."])
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
    runSend()
default:
    emit(["ok": false, "message": "Unknown cmux-imsg command: \(command)"])
    Foundation.exit(64)
}
