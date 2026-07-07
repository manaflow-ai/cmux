package com.manaflow.cmux.mux;

import java.util.Map;

public record Size(int cols, int rows) {
    static Size from(Map<String, Object> data) {
        return new Size((int) MuxClient.asLong(data.get("cols")), (int) MuxClient.asLong(data.get("rows")));
    }
}
