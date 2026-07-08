package com.cmux;

import java.util.Map;

public record Size(int cols, int rows) {
    static Size from(Map<String, Object> data) {
        return new Size((int) CmuxClient.asLong(data.get("cols")), (int) CmuxClient.asLong(data.get("rows")));
    }
}
