package com.manaflow.cmux.mux;

import java.util.Map;

public record IdentifyResult(String app, String version, int protocol, String session, long pid) {
    static IdentifyResult from(Map<String, Object> data) {
        return new IdentifyResult(
            MuxClient.asString(data.get("app")),
            MuxClient.asString(data.get("version")),
            (int) MuxClient.asLong(data.get("protocol")),
            MuxClient.asString(data.get("session")),
            MuxClient.asLong(data.get("pid"))
        );
    }
}
