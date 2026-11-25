//! The omnibox calculator row's arithmetic, ported 1:1 from the app's Swift
//! (`OmniboxCalculator`, Omnibox/Suggest/OmniboxCalculator.swift; plans/cmux-next/omnibar-suggestions.md,
//! "Sources"): `+ - * / % ^`, `×` and `÷`, parentheses, unary minus and decimals, by recursive
//! descent. Input that is not a whole expression with at least one operator (a plain number, a
//! word) has no value.

/// The value of `text`, or `None`.
pub fn evaluate(text: &str) -> Option<f64> {
    let value = Parser::new(text).parse()?;
    value.is_finite().then_some(value)
}

/// The answer as shown and copied: an integer without a fraction, else up to 10 significant
/// digits, in plain decimal notation ("0.3333333333").
pub fn format(value: f64) -> String {
    if value == value.round() && value.abs() < 1e15 {
        return (value as i64).to_string();
    }
    significant_digits(value, 10)
}

/// The answer for typed `text` (trimmed, at most 256 UTF-16 units), or `None` when it is not
/// arithmetic or the answer is the text itself.
pub fn answer(text: &str) -> Option<String> {
    let trimmed = text.trim();
    if trimmed.encode_utf16().count() > 256 {
        return None;
    }
    let answer = format(evaluate(trimmed)?);
    (answer != trimmed).then_some(answer)
}

/// `value` rounded to `digits` significant digits, in plain decimal notation with no trailing
/// zeros (NumberFormatter's decimal style with `maximumSignificantDigits`, en_US_POSIX, no
/// grouping).
fn significant_digits(value: f64, digits: usize) -> String {
    // Scientific form gives the rounded digits and the exponent: "-3.333333333e-1".
    let precision = digits - 1;
    let scientific = format!("{value:.precision$e}");
    let (mantissa, exponent) = scientific.split_once('e').unwrap_or((&scientific, "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let negative = mantissa.starts_with('-');
    let digits: String = mantissa.chars().filter(char::is_ascii_digit).collect();
    let digits = digits.trim_end_matches('0');
    let digits = if digits.is_empty() { "0" } else { digits };
    let mut out = String::new();
    if negative {
        out.push('-');
    }
    let point = exponent + 1;
    if point <= 0 {
        out.push_str("0.");
        out.extend(std::iter::repeat_n('0', point.unsigned_abs() as usize));
        out.push_str(digits);
    } else {
        let point = point as usize;
        if digits.len() <= point {
            out.push_str(digits);
            out.extend(std::iter::repeat_n('0', point - digits.len()));
        } else {
            out.push_str(&digits[..point]);
            out.push('.');
            out.push_str(&digits[point..]);
        }
    }
    out
}

/// Recursive descent: sum := product (('+'|'-') product)*; product := power (('*'|'/'|'%')
/// power)*; power := unary ('^' power)?; unary := '-' unary | '+' unary | atom;
/// atom := number | '(' sum ')'.
struct Parser {
    characters: Vec<char>,
    index: usize,
    operators: usize,
}

impl Parser {
    fn new(text: &str) -> Self {
        let characters = text
            .chars()
            .filter(|character| !character.is_whitespace())
            .map(|character| match character {
                '×' => '*',
                '÷' => '/',
                other => other,
            })
            .collect();
        Self { characters, index: 0, operators: 0 }
    }

    fn parse(&mut self) -> Option<f64> {
        if self.characters.is_empty() {
            return None;
        }
        let value = self.sum()?;
        (self.index == self.characters.len() && self.operators > 0).then_some(value)
    }

    fn next(&self) -> Option<char> {
        self.characters.get(self.index).copied()
    }

    fn sum(&mut self) -> Option<f64> {
        let mut value = self.product()?;
        while let Some(op @ ('+' | '-')) = self.next() {
            self.index += 1;
            self.operators += 1;
            let rhs = self.product()?;
            value = if op == '+' { value + rhs } else { value - rhs };
        }
        Some(value)
    }

    fn product(&mut self) -> Option<f64> {
        let mut value = self.power()?;
        while let Some(op @ ('*' | '/' | '%')) = self.next() {
            self.index += 1;
            self.operators += 1;
            let rhs = self.power()?;
            value = match op {
                '*' => value * rhs,
                '/' => value / rhs,
                _ => value % rhs,
            };
        }
        Some(value)
    }

    fn power(&mut self) -> Option<f64> {
        let base = self.unary()?;
        if self.next() != Some('^') {
            return Some(base);
        }
        self.index += 1;
        self.operators += 1;
        let exponent = self.power()?;
        Some(base.powf(exponent))
    }

    fn unary(&mut self) -> Option<f64> {
        if let Some(sign @ ('-' | '+')) = self.next() {
            self.index += 1;
            return self.unary().map(|value| if sign == '-' { -value } else { value });
        }
        self.atom()
    }

    fn atom(&mut self) -> Option<f64> {
        if self.next() == Some('(') {
            self.index += 1;
            let value = self.sum()?;
            if self.next() != Some(')') {
                return None;
            }
            self.index += 1;
            return Some(value);
        }
        let start = self.index;
        while let Some(character) = self.next() {
            if character.is_ascii_digit() || character == '.' {
                self.index += 1;
            } else {
                break;
            }
        }
        if self.index == start {
            return None;
        }
        let number: String = self.characters[start..self.index].iter().collect();
        number.parse().ok()
    }
}
