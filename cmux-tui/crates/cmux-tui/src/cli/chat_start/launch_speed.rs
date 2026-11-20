use serde_json::{Value, json};

/// Apply the tier the newly created harness advertises before releasing its first prompt.
/// A failed option write still leaves a real chat. Identify it and never repeat the start.
pub(super) fn enable(
    target: &str,
    receipt: &Value,
    call: &mut impl FnMut(&[&str], Option<&str>) -> Result<Value, Value>,
) -> Result<(), Value> {
    let fail = |reason: &str| {
        json!({"code":"chat.fast_unavailable","retryable":false,
        "message":format!("{target} started, but fast mode was not confirmed: {reason}. No prompt was sent. Inspect this chat with `cmux acp session info {target}`."), "details":{"session_id":target}})
    };
    let id = receipt["sessionId"]
        .as_str()
        .or(receipt["detail"].as_str())
        .ok_or_else(|| fail("missing session ID"))?;
    let info = call(&["session", "info", target, "--json"], None)
        .map_err(|e| fail(e["message"].as_str().unwrap_or("cannot read session options")))?;
    if info["sessionId"].as_str() != Some(id) {
        return Err(fail("session ID did not match the start receipt"));
    }
    let option = info["configOptions"]
        .as_array()
        .and_then(|options| options.iter().find(|o| o["id"] == "fast-mode"))
        .ok_or_else(|| fail("the harness did not advertise fast mode"))?;
    let choices =
        option["options"].as_array().ok_or_else(|| fail("no speed choices were advertised"))?;
    let tier = ["fast", "priority", "on"]
        .into_iter()
        .find(|tier| choices.iter().any(|c| c["value"].as_str() == Some(*tier)))
        .ok_or_else(|| fail("this model did not offer a faster tier"))?;
    if option["currentValue"].as_str() != Some(tier) {
        let assignment = format!("fast-mode={tier}");
        let key = target
            .rsplit_once('/')
            .map_or_else(|| id.to_owned(), |(host, _)| format!("{host}/{id}"));
        let changed = call(&["session", "set", &key, &assignment, "--json"], None)
            .map_err(|e| fail(e["message"].as_str().unwrap_or("setting refused")))?;
        if !changed["configOptions"].as_array().is_some_and(|options| {
            options
                .iter()
                .any(|o| o["id"] == "fast-mode" && o["currentValue"].as_str() == Some(tier))
        }) {
            return Err(fail("the harness did not confirm the selected speed"));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_fast_launch_sets_the_advertised_tier_before_sending_any_prompt() {
        for (tier, supported) in [("priority", true), ("on", true), ("default", false)] {
            let mut calls = Vec::new();
            let started = json!({"sessionId":"mux-1"});
            let result = enable("vm/demo", &started, &mut |words, _| {
                calls.push(words.join(" "));
                if words[1] == "set" {
                    return Ok(json!({"configOptions":[{"id":"fast-mode","currentValue":tier}]}));
                }
                Ok(
                    json!({"sessionId":"mux-1", "configOptions":[{"id":"fast-mode","options":[{"value":tier}]}]}),
                )
            });
            assert_eq!(result.is_ok(), supported);
            assert_eq!(calls.len(), if supported { 2 } else { 1 });
            if supported {
                assert_eq!(calls[1], format!("session set vm/mux-1 fast-mode={tier} --json"));
            }
        }
    }
}
