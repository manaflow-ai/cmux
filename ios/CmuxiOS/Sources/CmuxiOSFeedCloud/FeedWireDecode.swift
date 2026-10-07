import CmuxiOSFeatureKit
import Foundation

/// Decodes the owner's JSON item (backend `FeedItem`, feed.md 3.1:
/// snake_case, times in ms) into the seam model. Pure; unknown kinds become
/// `.unsupported` so one odd item never hides the rest of the feed.
struct FeedWireDecode {
    typealias Object = [String: Any]

    static func date(_ any: Any?) -> Date? {
        guard let number = any as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }

    static func strings(_ any: Any?) -> [String] { (any as? [Any])?.compactMap { $0 as? String } ?? [] }

    static func item(_ o: Object) -> FeedItem? {
        guard let id = o["id"] as? String, let title = o["title"] as? String,
              let created = date(o["created_at"]) else { return nil }
        let poster = o["poster"] as? Object ?? [:]
        let context = o["context"] as? Object ?? [:]
        let type = o["type"] as? String ?? "notice"
        let kind = type == "notice" ? FeedItemKind.done : self.kind(o["kind"] as? String ?? "", o["prompt"] as? Object ?? [:])
        return FeedItem(
            id: id,
            kind: kind,
            state: FeedItemState(rawValue: o["state"] as? String ?? "") ?? .open,
            priority: FeedPriority(rawValue: o["priority"] as? String ?? "") ?? .normal,
            hostID: (context["host"] as? String).map(HostID.init(rawValue:)),
            workspaceID: context["workspace"] as? String,
            source: poster["label"] as? String ?? "",
            agent: (poster["harness"] as? String) ?? (poster["agent"] as? String),
            title: title,
            body: o["body"] as? String ?? "",
            createdAt: created,
            expiresAt: date(o["expires_at"]),
            readAt: date(o["read_at"]),
            seenAt: date(o["seen_at"]),
            archivedAt: date(o["archived_at"]),
            answer: (o["answer"] as? Object).flatMap { answerRecord($0, kind: kind) },
            cancelReason: ((o["cancel"] as? Object)?["reason"] as? String).map { FeedCancelReason(rawValue: $0) ?? .other },
            revision: (o["revision"] as? Int) ?? 1
        )
    }

    static func kind(_ name: String, _ p: Object) -> FeedItemKind {
        let s = { (key: String) in p[key] as? String }
        switch name {
        case "approve":
            let a = p["action"] as? Object ?? [:]
            return .permission(FeedPermission(
                actionType: FeedPermission.ActionType(rawValue: a["type"] as? String ?? "") ?? .custom,
                summary: a["summary"] as? String ?? "", command: a["command"] as? String, cwd: a["cwd"] as? String,
                tool: a["tool"] as? String, risk: a["risk"] as? String,
                scopes: strings(p["scopes"]).compactMap(FeedPermissionScope.init(rawValue:))))
        case "question":
            return .question(FeedQuestion(question: s("question") ?? "", suggestions: strings(p["suggestions"]),
                                          multiline: p["multiline"] as? Bool ?? false))
        case "choice":
            let questions = ((p["questions"] as? [Object]) ?? []).map { q in
                FeedChoiceQuestion(
                    id: q["id"] as? String ?? "", question: q["question"] as? String ?? "", header: q["header"] as? String,
                    options: ((q["options"] as? [Object]) ?? []).map {
                        FeedChoiceOption(id: $0["id"] as? String ?? "", label: $0["label"] as? String ?? "",
                                         detail: $0["description"] as? String)
                    },
                    multi: q["multi"] as? Bool ?? false, allowOther: q["allow_other"] as? Bool ?? false)
            }
            return .choice(FeedChoice(questions: questions))
        case "review":
            guard s("subject") == "plan" else { return .unsupported(kind: name, needsMac: false) }
            return .planApproval(FeedPlan(ref: s("ref") ?? "", checklist: strings(p["checklist"])))
        case "confirm":
            return .confirm(FeedConfirm(statement: s("statement") ?? "", confirmLabel: s("confirm_label"),
                                        cancelLabel: s("cancel_label"), destructive: p["destructive"] as? Bool ?? false))
        case "sign-in", "passkey", "handoff":
            return .unsupported(kind: name, needsMac: true)
        default:
            return .unsupported(kind: name, needsMac: false)
        }
    }

    static func answerRecord(_ o: Object, kind: FeedItemKind) -> FeedAnswerRecord? {
        guard let at = date(o["at"]) else { return nil }
        return FeedAnswerRecord(reply: reply(o["value"] as? Object ?? [:], kind: kind), device: o["device"] as? String, at: at)
    }

    static func reply(_ v: Object, kind: FeedItemKind) -> FeedReply? {
        switch kind {
        case .permission:
            guard let decision = v["decision"] as? String else { return nil }
            return .permission(allow: decision == "allow",
                               scope: (v["scope"] as? String).flatMap(FeedPermissionScope.init(rawValue:)))
        case .question:
            return (v["text"] as? String).map(FeedReply.text)
        case .choice:
            guard let answers = v["answers"] as? Object else { return nil }
            return .choice(answers.compactMapValues { value in
                guard let value = value as? Object else { return nil }
                return FeedChoiceSelection(selected: strings(value["selected"]), other: value["other"] as? String)
            })
        case .planApproval:
            guard let verdict = v["verdict"] as? String else { return nil }
            return .plan(approved: verdict == "approve", comment: v["comment"] as? String)
        case .confirm:
            return (v["confirmed"] as? Bool).map(FeedReply.confirm)
        case .done, .unsupported:
            return nil
        }
    }
}
