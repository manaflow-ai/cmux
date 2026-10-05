//! Network events for `page.on("request" | "response" | "requestfailed" |
//! "requestfinished")`, from the CDP `Network` domain of a tab's sessions.
//! Payload: `{ targetId, requestId, url, method, resourceType, status?,
//! headers?, errorText? }` (driver-protocol.md events).

use super::state::TabState;
use crate::protocol::DriverEvent;
use serde_json::{Map, Value, json};

/// Requests a tab remembers until they finish or fail (the oldest go first).
const MAX_OPEN_REQUESTS: usize = 1000;

/// Responses a tab remembers the address of (net.fetch's rebinding check).
const MAX_RESPONSES: usize = 256;

/// What a request's later events need from its first one.
#[derive(Debug, Clone)]
pub struct OpenRequest {
    url: String,
    method: String,
    resource_type: String,
}

fn payload(request_id: &str, open: &OpenRequest) -> Map<String, Value> {
    let mut payload = Map::new();
    payload.insert("requestId".into(), json!(request_id));
    payload.insert("url".into(), json!(open.url));
    payload.insert("method".into(), json!(open.method));
    payload.insert("resourceType".into(), json!(open.resource_type));
    payload
}

/// The driver event for a `Network.*` CDP event of a tab, if any.
pub fn event(
    tab: &mut TabState,
    target_id: &str,
    method: &str,
    params: &Value,
) -> Option<DriverEvent> {
    let request_id = params.get("requestId").and_then(Value::as_str)?.to_owned();
    let (name, payload) = match method {
        "Network.requestWillBeSent" => {
            let request = &params["request"];
            let open = OpenRequest {
                url: request["url"].as_str().unwrap_or("").to_owned(),
                method: request["method"].as_str().unwrap_or("GET").to_owned(),
                resource_type: params["type"].as_str().unwrap_or("Other").to_ascii_lowercase(),
            };
            let mut payload = payload(&request_id, &open);
            payload.insert("headers".into(), request.get("headers").cloned().unwrap_or(json!({})));
            if tab.requests.len() >= MAX_OPEN_REQUESTS
                && let Some(oldest) = tab.request_order.pop_front()
            {
                tab.requests.remove(&oldest);
            }
            if tab.requests.insert(request_id.clone(), open).is_none() {
                tab.request_order.push_back(request_id);
            }
            ("request", payload)
        }
        "Network.responseReceived" => {
            let response = &params["response"];
            if let (Some(url), Some(ip)) = (
                response.get("url").and_then(Value::as_str),
                response.get("remoteIPAddress").and_then(Value::as_str),
            ) {
                if tab.responses.len() >= MAX_RESPONSES {
                    tab.responses.pop_front();
                }
                tab.responses.push_back((url.to_owned(), ip.to_owned()));
            }
            let open = tab.requests.get(&request_id)?;
            let mut payload = payload(&request_id, open);
            payload.insert("status".into(), response.get("status").cloned().unwrap_or(json!(0)));
            payload.insert("headers".into(), response.get("headers").cloned().unwrap_or(json!({})));
            ("response", payload)
        }
        "Network.loadingFinished" | "Network.loadingFailed" => {
            let open = tab.requests.remove(&request_id)?;
            tab.request_order.retain(|id| *id != request_id);
            let mut payload = payload(&request_id, &open);
            let name = if method == "Network.loadingFailed" {
                payload.insert(
                    "errorText".into(),
                    params.get("errorText").cloned().unwrap_or(json!("")),
                );
                "requestfailed"
            } else {
                "requestfinished"
            };
            (name, payload)
        }
        _ => return None,
    };
    let mut payload = payload;
    payload.insert("targetId".into(), json!(target_id));
    Some(DriverEvent { name: name.to_owned(), payload: Value::Object(payload) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_request_reports_its_response_and_end() {
        let mut tab = TabState::new("S1".into(), String::new(), String::new(), None);
        let sent = json!({"requestId": "r1", "type": "Fetch",
            "request": {"url": "http://a.test/api/data", "method": "GET", "headers": {"accept": "*/*"}}});
        let request = event(&mut tab, "T1", "Network.requestWillBeSent", &sent).unwrap();
        assert_eq!(request.name, "request");
        assert_eq!(
            (
                &request.payload["method"],
                &request.payload["resourceType"],
                &request.payload["targetId"]
            ),
            (&json!("GET"), &json!("fetch"), &json!("T1"))
        );
        let response = event(
            &mut tab,
            "T1",
            "Network.responseReceived",
            &json!({"requestId": "r1", "response": {"status": 200, "headers": {}}}),
        )
        .unwrap();
        assert_eq!(
            (response.name.as_str(), &response.payload["status"]),
            ("response", &json!(200))
        );
        assert_eq!(response.payload["url"], "http://a.test/api/data");
        let done =
            event(&mut tab, "T1", "Network.loadingFinished", &json!({"requestId": "r1"})).unwrap();
        assert_eq!(done.name, "requestfinished");
        assert!(tab.requests.is_empty() && tab.request_order.is_empty());
        assert!(
            event(&mut tab, "T1", "Network.loadingFailed", &json!({"requestId": "r1"})).is_none(),
            "an unknown request has no event"
        );
    }

    #[test]
    fn open_requests_are_bounded() {
        let mut tab = TabState::new("S1".into(), String::new(), String::new(), None);
        for i in 0..(MAX_OPEN_REQUESTS + 5) {
            let sent = json!({"requestId": format!("r{i}"), "type": "XHR", "request": {"url": "http://a.test/", "method": "GET"}});
            event(&mut tab, "T1", "Network.requestWillBeSent", &sent);
        }
        assert_eq!(tab.requests.len(), MAX_OPEN_REQUESTS);
        assert!(!tab.requests.contains_key("r0"));
    }
}
