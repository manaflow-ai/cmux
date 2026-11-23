#[cfg(not(test))]
#[cfg(feature = "log")]
#[collapse_debuginfo(yes)]
macro_rules! net_log {
    (trace, $($arg:expr),*) => { log::trace!($($arg),*) };
    (debug, $($arg:expr),*) => { log::debug!($($arg),*) };
}

#[cfg(test)]
#[cfg(feature = "log")]
#[collapse_debuginfo(yes)]
macro_rules! net_log {
    (trace, $($arg:expr),*) => { println!($($arg),*) };
    (debug, $($arg:expr),*) => { println!($($arg),*) };
}

#[cfg(feature = "defmt")]
#[collapse_debuginfo(yes)]
macro_rules! net_log {
    (trace, $($arg:expr),*) => { defmt::trace!($($arg),*) };
    (debug, $($arg:expr),*) => { defmt::debug!($($arg),*) };
}

#[cfg(not(any(feature = "log", feature = "defmt")))]
#[collapse_debuginfo(yes)]
macro_rules! net_log {
    ($level:ident, $($arg:expr),*) => {{ $( let _ = $arg; )* }}
}

#[collapse_debuginfo(yes)]
macro_rules! net_trace {
    ($($arg:expr),*) => (net_log!(trace, $($arg),*));
}

#[collapse_debuginfo(yes)]
macro_rules! net_debug {
    ($($arg:expr),*) => (net_log!(debug, $($arg),*));
}

macro_rules! enum_with_unknown {
    (
        $( #[$enum_attr:meta] )*
        pub enum $name:ident($ty:ty) {
            $(
              $( #[$variant_attr:meta] )*
              $variant:ident = $value:expr
            ),+ $(,)?
        }
    ) => {
        #[derive(Debug, PartialEq, Eq, PartialOrd, Ord, Clone, Copy, Hash)]
        #[cfg_attr(feature = "defmt", derive(defmt::Format))]
        $( #[$enum_attr] )*
        pub enum $name {
            $(
              $( #[$variant_attr] )*
              $variant
            ),*,
            Unknown($ty)
        }

        impl ::core::convert::From<$ty> for $name {
            fn from(value: $ty) -> Self {
                match value {
                    $( $value => $name::$variant ),*,
                    other => $name::Unknown(other)
                }
            }
        }

        impl ::core::convert::From<$name> for $ty {
            fn from(value: $name) -> Self {
                match value {
                    $( $name::$variant => $value ),*,
                    $name::Unknown(other) => other
                }
            }
        }
    }
}

#[cfg(feature = "proto-rpl")]
macro_rules! get {
    ($buffer:expr, into: $into:ty, fun: $fun:ident, field: $field:expr $(,)?) => {
        {
            <$into>::$fun(&$buffer.as_ref()[$field])
        }
    };

    ($buffer:expr, into: $into:ty, field: $field:expr $(,)?) => {
        get!($buffer, into: $into, field: $field, shift: 0, mask: 0b1111_1111)
    };

    ($buffer:expr, into: $into:ty, field: $field:expr, mask: $bit_mask:expr $(,)?) => {
        get!($buffer, into: $into, field: $field, shift: 0, mask: $bit_mask)
    };

    ($buffer:expr, into: $into:ty, field: $field:expr, shift: $bit_shift:expr, mask: $bit_mask:expr $(,)?) => {
        {
            <$into>::from((&$buffer.as_ref()[$field] >> $bit_shift) & $bit_mask)
        }
    };

    ($buffer:expr, field: $field:expr $(,)?) => {
        get!($buffer, field: $field, shift: 0, mask: 0b1111_1111)
    };

    ($buffer:expr, field: $field:expr, mask: $bit_mask:expr $(,)?) => {
        get!($buffer, field: $field, shift: 0, mask: $bit_mask)
    };

    ($buffer:expr, field: $field:expr, shift: $bit_shift:expr, mask: $bit_mask:expr $(,)?)
        =>
    {
        {
            (&$buffer.as_ref()[$field] >> $bit_shift) & $bit_mask
        }
    };

    ($buffer:expr, u16, field: $field:expr $(,)?) => {
        {
            NetworkEndian::read_u16(&$buffer.as_ref()[$field])
        }
    };

    ($buffer:expr, bool, field: $field:expr, shift: $bit_shift:expr, mask: $bit_mask:expr $(,)?) => {
        {
            (($buffer.as_ref()[$field] >> $bit_shift) & $bit_mask) == 0b1
        }
    };

    ($buffer:expr, u32, field: $field:expr $(,)?) => {
        {
            NetworkEndian::read_u32(&$buffer.as_ref()[$field])
        }
    };
}

#[cfg(feature = "proto-rpl")]
macro_rules! set {
    ($buffer:expr, address: $address:ident, field: $field:expr $(,)?) => {{
        $buffer.as_mut()[$field].copy_from_slice(&$address.octets());
    }};

    ($buffer:expr, $value:ident, field: $field:expr $(,)?) => {
        set!($buffer, $value, field: $field, shift: 0, mask: 0b1111_1111)
    };

    ($buffer:expr, $value:ident, field: $field:expr, mask: $bit_mask:expr $(,)?) => {
        set!($buffer, $value, field: $field, shift: 0, mask: $bit_mask)
    };

    ($buffer:expr, $value:ident, field: $field:expr, shift: $bit_shift:expr, mask: $bit_mask:expr $(,)?) => {{
        let raw =
            ($buffer.as_ref()[$field] & !($bit_mask << $bit_shift)) | ($value << $bit_shift);
        $buffer.as_mut()[$field] = raw;
    }};

    ($buffer:expr, $value:ident, bool, field: $field:expr, mask: $bit_mask:expr $(,)?) => {
        set!($buffer, $value, bool, field: $field, shift: 0, mask: $bit_mask);
    };

    ($buffer:expr, $value:ident, bool, field: $field:expr, shift: $bit_shift:expr, mask: $bit_mask:expr $(,)?) => {{
        let raw = ($buffer.as_ref()[$field] & !($bit_mask << $bit_shift))
            | (if $value { 0b1 } else { 0b0 } << $bit_shift);
        $buffer.as_mut()[$field] = raw;
    }};

    ($buffer:expr, $value:ident, u16, field: $field:expr $(,)?) => {{
        NetworkEndian::write_u16(&mut $buffer.as_mut()[$field], $value);
    }};

    ($buffer:expr, $value:ident, u32, field: $field:expr $(,)?) => {{
        NetworkEndian::write_u32(&mut $buffer.as_mut()[$field], $value);
    }};
}
