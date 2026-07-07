package com.manaflow.cmux.mux;

import java.util.List;
import java.util.Map;
import java.util.LinkedHashMap;

public final class JsonTest {
    @SuppressWarnings("unchecked")
    public static void main(String[] args) {
        Object parsed = Json.parse("{\"s\":\"a\\n\\t\\\\\\\"\",\"u\":\"\\uD83D\\uDE00\",\"n\":-12.5e2,\"a\":[true,false,null,{\"x\":1}]}");
        Map<String, Object> object = (Map<String, Object>) parsed;
        assertEquals("a\n\t\\\"", object.get("s"), "string escapes");
        assertEquals("😀", object.get("u"), "surrogate pair");
        assertEquals(-1250.0, object.get("n"), "number");
        List<Object> array = (List<Object>) object.get("a");
        assertEquals(Boolean.TRUE, array.get(0), "array true");
        assertEquals(Boolean.FALSE, array.get(1), "array false");
        assertEquals(null, array.get(2), "array null");
        assertEquals(1L, ((Map<String, Object>) array.get(3)).get("x"), "nested object");

        Map<String, Object> expected = new LinkedHashMap<>();
        expected.put("a", List.of(1L, "two"));
        expected.put("b", "line\n");
        String encoded = Json.stringify(expected);
        Object roundTrip = Json.parse(encoded);
        assertEquals(expected, roundTrip, "round trip equality");
        assertReject("[1,]");
        assertReject("{\"x\":}");
        assertReject("\"\\uD800\"");
        assertReject("01");
        assertReject("١");
        assertReject("\"\\u１２３4\"");
        assertStringifyReject(Double.NaN);
        assertStringifyReject(Double.POSITIVE_INFINITY);
    }

    private static void assertReject(String input) {
        try {
            Json.parse(input);
            throw new AssertionError("accepted malformed input: " + input);
        } catch (JsonException expected) {
            // expected
        }
    }

    private static void assertTrue(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    private static void assertEquals(Object expected, Object actual, String message) {
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError(message + " expected=" + expected + " actual=" + actual);
        }
    }

    private static void assertStringifyReject(Object value) {
        try {
            Json.stringify(value);
            throw new AssertionError("stringified malformed value: " + value);
        } catch (JsonException expected) {
            // expected
        }
    }
}
