//! NDEF message parsing and encoding for NFC Forum Type 2 tags.

pub struct ParsedNdef {
    pub url: Option<String>,
    pub text: Option<String>,
    pub attend_token: Option<String>,
    pub raw_hex: String,
}

const ATTEND_TYPE: &[u8] = b"hackclub.com:attend";

const URI_PREFIXES: &[(&str, u8)] = &[
    ("https://www.", 0x02),
    ("http://www.", 0x01),
    ("https://", 0x04),
    ("http://", 0x03),
    ("tel:", 0x05),
    ("mailto:", 0x06),
];

pub fn parse(raw: &[u8]) -> ParsedNdef {
    let raw_hex = hex(raw);
    let mut url = None;
    let mut text = None;
    let mut attend_token = None;

    let mut i = 0usize;
    while i + 3 < raw.len() {
        let header = raw[i];
        let tnf = header & 0x07;
        let sr = header & 0x10 != 0;
        let il = header & 0x08 != 0;
        i += 1;

        if i >= raw.len() {
            break;
        }
        let type_len = raw[i] as usize;
        i += 1;
        if i >= raw.len() {
            break;
        }

        let payload_len = if sr {
            let l = raw[i] as usize;
            i += 1;
            l
        } else {
            if i + 4 > raw.len() {
                break;
            }
            let l = ((raw[i] as usize) << 24)
                | ((raw[i + 1] as usize) << 16)
                | ((raw[i + 2] as usize) << 8)
                | raw[i + 3] as usize;
            i += 4;
            l
        };

        if il {
            if i >= raw.len() {
                break;
            }
            i += raw[i] as usize + 1;
        }

        if i + type_len > raw.len() {
            break;
        }
        let type_data = &raw[i..i + type_len];
        i += type_len;

        if i + payload_len > raw.len() {
            break;
        }
        let payload = &raw[i..i + payload_len];
        i += payload_len;

        match tnf {
            0x01 => {
                // Well-known type
                if type_data == [0x55] && !payload.is_empty() {
                    url = decode_uri(payload);
                } else if type_data == [0x54] && !payload.is_empty() {
                    text = decode_text(payload);
                }
            }
            0x04 => {
                // External type
                if type_data == ATTEND_TYPE {
                    attend_token = String::from_utf8(payload.to_vec()).ok();
                }
            }
            _ => {}
        }
    }

    ParsedNdef {
        url,
        text,
        attend_token,
        raw_hex,
    }
}

fn decode_uri(payload: &[u8]) -> Option<String> {
    let prefix = match payload[0] {
        0x00 => "",
        0x01 => "http://www.",
        0x02 => "https://www.",
        0x03 => "http://",
        0x04 => "https://",
        0x05 => "tel:",
        0x06 => "mailto:",
        _ => "",
    };
    let rest = String::from_utf8_lossy(&payload[1..]);
    Some(format!("{prefix}{rest}"))
}

fn decode_text(payload: &[u8]) -> Option<String> {
    if payload.len() < 2 {
        return None;
    }
    let lang_len = (payload[0] & 0x3F) as usize;
    if payload.len() <= lang_len + 1 {
        return None;
    }
    String::from_utf8(payload[lang_len + 1..].to_vec()).ok()
}

/// Encode an NDEF message: a URI record, optionally followed by an
/// external `hackclub.com:attend` record carrying the attend token.
pub fn encode(badge_url: &str, attend_token: Option<&str>) -> Vec<u8> {
    match attend_token {
        Some(token) => {
            let mut msg = encode_uri_record(badge_url, true, false);
            msg.extend(encode_external_record(ATTEND_TYPE, token.as_bytes(), false, true));
            msg
        }
        None => encode_uri_record(badge_url, true, true),
    }
}

fn encode_uri_record(url: &str, first: bool, last: bool) -> Vec<u8> {
    let mut prefix_code = 0x00u8;
    let mut rest = url;
    for (prefix, code) in URI_PREFIXES {
        if let Some(stripped) = url.strip_prefix(prefix) {
            prefix_code = *code;
            rest = stripped;
            break;
        }
    }

    let mut payload = vec![prefix_code];
    payload.extend(rest.as_bytes());

    // SR=1, TNF=0x01 (well-known)
    let mut header = 0x11u8;
    if first {
        header |= 0x80; // MB
    }
    if last {
        header |= 0x40; // ME
    }

    let mut record = vec![header, 0x01, payload.len() as u8, 0x55];
    record.extend(payload);
    record
}

fn encode_external_record(type_bytes: &[u8], payload: &[u8], first: bool, last: bool) -> Vec<u8> {
    // SR=1, TNF=0x04 (external)
    let mut header = 0x14u8;
    if first {
        header |= 0x80;
    }
    if last {
        header |= 0x40;
    }

    let mut record = vec![header, type_bytes.len() as u8, payload.len() as u8];
    record.extend(type_bytes);
    record.extend(payload);
    record
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02X}")).collect()
}
