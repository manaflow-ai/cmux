package com.manaflow.cmux.mux;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class Json {
    private Json() {}

    public static Object parse(String text) {
        Parser parser = new Parser(text);
        Object value = parser.parseValue();
        parser.skipWhitespace();
        if (!parser.isEnd()) {
            throw new JsonException("trailing input at byte " + parser.index);
        }
        return value;
    }

    public static String stringify(Object value) {
        StringBuilder out = new StringBuilder();
        write(value, out);
        return out.toString();
    }

    @SuppressWarnings("unchecked")
    private static void write(Object value, StringBuilder out) {
        if (value == null) {
            out.append("null");
        } else if (value instanceof String text) {
            writeString(text, out);
        } else if (value instanceof Number number) {
            if (number instanceof Double doubleValue && !Double.isFinite(doubleValue)) {
                throw new JsonException("non-finite JSON number");
            }
            if (number instanceof Float floatValue && !Float.isFinite(floatValue)) {
                throw new JsonException("non-finite JSON number");
            }
            out.append(number);
        } else if (value instanceof Boolean) {
            out.append(value);
        } else if (value instanceof Map<?, ?> map) {
            out.append('{');
            boolean first = true;
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                if (!(entry.getKey() instanceof String key)) {
                    throw new JsonException("object keys must be strings");
                }
                if (!first) {
                    out.append(',');
                }
                first = false;
                writeString(key, out);
                out.append(':');
                write(entry.getValue(), out);
            }
            out.append('}');
        } else if (value instanceof Iterable<?> items) {
            out.append('[');
            boolean first = true;
            for (Object item : items) {
                if (!first) {
                    out.append(',');
                }
                first = false;
                write(item, out);
            }
            out.append(']');
        } else if (value.getClass().isArray()) {
            out.append('[');
            int length = java.lang.reflect.Array.getLength(value);
            for (int i = 0; i < length; i++) {
                if (i > 0) {
                    out.append(',');
                }
                write(java.lang.reflect.Array.get(value, i), out);
            }
            out.append(']');
        } else {
            throw new JsonException("unsupported JSON value: " + value.getClass().getName());
        }
    }

    private static void writeString(String value, StringBuilder out) {
        out.append('"');
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"' -> out.append("\\\"");
                case '\\' -> out.append("\\\\");
                case '\b' -> out.append("\\b");
                case '\f' -> out.append("\\f");
                case '\n' -> out.append("\\n");
                case '\r' -> out.append("\\r");
                case '\t' -> out.append("\\t");
                default -> {
                    if (c < 0x20) {
                        out.append(String.format("\\u%04x", (int) c));
                    } else {
                        out.append(c);
                    }
                }
            }
        }
        out.append('"');
    }

    private static final class Parser {
        private final String text;
        private int index;

        Parser(String text) {
            this.text = text;
        }

        boolean isEnd() {
            return index >= text.length();
        }

        void skipWhitespace() {
            while (!isEnd()) {
                char c = text.charAt(index);
                if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
                    index++;
                } else {
                    break;
                }
            }
        }

        Object parseValue() {
            skipWhitespace();
            if (isEnd()) {
                throw new JsonException("unexpected end of input");
            }
            return switch (text.charAt(index)) {
                case '{' -> parseObject();
                case '[' -> parseArray();
                case '"' -> parseString();
                case 't' -> literal("true", Boolean.TRUE);
                case 'f' -> literal("false", Boolean.FALSE);
                case 'n' -> literal("null", null);
                default -> parseNumber();
            };
        }

        private Map<String, Object> parseObject() {
            index++;
            LinkedHashMap<String, Object> object = new LinkedHashMap<>();
            skipWhitespace();
            if (consume('}')) {
                return object;
            }
            while (true) {
                skipWhitespace();
                if (isEnd() || text.charAt(index) != '"') {
                    throw new JsonException("expected object key at byte " + index);
                }
                String key = parseString();
                skipWhitespace();
                expect(':');
                object.put(key, parseValue());
                skipWhitespace();
                if (consume('}')) {
                    return object;
                }
                expect(',');
            }
        }

        private List<Object> parseArray() {
            index++;
            ArrayList<Object> array = new ArrayList<>();
            skipWhitespace();
            if (consume(']')) {
                return array;
            }
            while (true) {
                array.add(parseValue());
                skipWhitespace();
                if (consume(']')) {
                    return array;
                }
                expect(',');
            }
        }

        private String parseString() {
            expect('"');
            StringBuilder out = new StringBuilder();
            while (!isEnd()) {
                char c = text.charAt(index++);
                if (c == '"') {
                    return out.toString();
                }
                if (c == '\\') {
                    if (isEnd()) {
                        throw new JsonException("unterminated escape");
                    }
                    char esc = text.charAt(index++);
                    switch (esc) {
                        case '"', '\\', '/' -> out.append(esc);
                        case 'b' -> out.append('\b');
                        case 'f' -> out.append('\f');
                        case 'n' -> out.append('\n');
                        case 'r' -> out.append('\r');
                        case 't' -> out.append('\t');
                        case 'u' -> appendUnicode(out);
                        default -> throw new JsonException("bad escape \\" + esc + " at byte " + (index - 1));
                    }
                } else {
                    if (c < 0x20) {
                        throw new JsonException("control character in string at byte " + (index - 1));
                    }
                    out.append(c);
                }
            }
            throw new JsonException("unterminated string");
        }

        private void appendUnicode(StringBuilder out) {
            int code = readHex4();
            if (Character.isHighSurrogate((char) code)) {
                if (index + 2 > text.length() || text.charAt(index) != '\\' || text.charAt(index + 1) != 'u') {
                    throw new JsonException("missing low surrogate");
                }
                index += 2;
                int low = readHex4();
                if (!Character.isLowSurrogate((char) low)) {
                    throw new JsonException("invalid low surrogate");
                }
                out.append(Character.toChars(Character.toCodePoint((char) code, (char) low)));
            } else if (Character.isLowSurrogate((char) code)) {
                throw new JsonException("unpaired low surrogate");
            } else {
                out.append((char) code);
            }
        }

        private int readHex4() {
            if (index + 4 > text.length()) {
                throw new JsonException("short unicode escape");
            }
            int value = 0;
            for (int i = 0; i < 4; i++) {
                int digit = asciiHexDigit(text.charAt(index++));
                if (digit < 0) {
                    throw new JsonException("bad unicode escape");
                }
                value = (value << 4) | digit;
            }
            return value;
        }

        private Object parseNumber() {
            int start = index;
            if (consume('-') && isEnd()) {
                throw new JsonException("bad number");
            }
            if (consume('0')) {
                if (!isEnd() && isAsciiDigit(text.charAt(index))) {
                    throw new JsonException("leading zero in number");
                }
            } else {
                if (isEnd() || !isAsciiDigit(text.charAt(index))) {
                    throw new JsonException("expected JSON value at byte " + index);
                }
                while (!isEnd() && isAsciiDigit(text.charAt(index))) {
                    index++;
                }
            }
            boolean floating = false;
            if (consume('.')) {
                floating = true;
                requireDigit();
                while (!isEnd() && isAsciiDigit(text.charAt(index))) {
                    index++;
                }
            }
            if (!isEnd() && (text.charAt(index) == 'e' || text.charAt(index) == 'E')) {
                floating = true;
                index++;
                if (!isEnd() && (text.charAt(index) == '+' || text.charAt(index) == '-')) {
                    index++;
                }
                requireDigit();
                while (!isEnd() && isAsciiDigit(text.charAt(index))) {
                    index++;
                }
            }
            String raw = text.substring(start, index);
            try {
                if (floating) {
                    double value = Double.parseDouble(raw);
                    if (!Double.isFinite(value)) {
                        throw new NumberFormatException(raw);
                    }
                    return value;
                }
                return Long.parseLong(raw);
            } catch (NumberFormatException err) {
                throw new JsonException("bad number " + raw);
            }
        }

        private void requireDigit() {
            if (isEnd() || !isAsciiDigit(text.charAt(index))) {
                throw new JsonException("expected digit at byte " + index);
            }
        }

        private boolean isAsciiDigit(char c) {
            return c >= '0' && c <= '9';
        }

        private int asciiHexDigit(char c) {
            if (c >= '0' && c <= '9') {
                return c - '0';
            }
            if (c >= 'a' && c <= 'f') {
                return 10 + c - 'a';
            }
            if (c >= 'A' && c <= 'F') {
                return 10 + c - 'A';
            }
            return -1;
        }

        private Object literal(String literal, Object value) {
            if (!text.startsWith(literal, index)) {
                throw new JsonException("expected " + literal + " at byte " + index);
            }
            index += literal.length();
            return value;
        }

        private boolean consume(char c) {
            if (!isEnd() && text.charAt(index) == c) {
                index++;
                return true;
            }
            return false;
        }

        private void expect(char c) {
            if (!consume(c)) {
                throw new JsonException("expected '" + c + "' at byte " + index);
            }
        }
    }
}
