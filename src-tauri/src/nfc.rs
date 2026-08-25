//! PC/SC reader polling. Works with any PC/SC-compatible NFC reader:
//! winscard on Windows, pcsclite (pcscd) on Linux, PCSC.framework on macOS.

use crate::ndef;
use crate::state::{AppCore, TagData};
use chrono::{SecondsFormat, Utc};
use pcsc::{Card, Context, Error as PcscError, Protocols, Scope, ShareMode};
use std::ffi::CString;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

const POLL_INTERVAL: Duration = Duration::from_millis(300);
const DEBOUNCE: Duration = Duration::from_millis(1500);

pub fn spawn_nfc_thread(core: AppCore) {
    std::thread::spawn(move || run(core));
}

fn run(core: AppCore) {
    let mut ctx: Option<Context> = None;
    let mut last_scan: Option<(String, Instant)> = None;

    while core.enabled.load(Ordering::SeqCst) {
        if core.reconnect_requested.swap(false, Ordering::SeqCst) {
            ctx = None;
        }

        if ctx.is_none() {
            ctx = Context::establish(Scope::System).ok();
            if ctx.is_none() {
                // PC/SC service unavailable (e.g. pcscd not running on Linux)
                core.set_reader_names(Vec::new());
                std::thread::sleep(Duration::from_secs(2));
                continue;
            }
        }

        let readers = match list_readers(ctx.as_ref().unwrap()) {
            Ok(names) => names,
            Err(reset) => {
                if reset {
                    ctx = None;
                }
                Vec::new()
            }
        };

        core.set_reader_names(readers.clone());

        let pending = core.pending_write.lock().unwrap().is_some();
        for name in &readers {
            let Ok(cname) = CString::new(name.as_str()) else {
                continue;
            };
            let Ok(card) = ctx
                .as_ref()
                .unwrap()
                .connect(&cname, ShareMode::Shared, Protocols::ANY)
            else {
                continue;
            };

            if pending {
                try_pending_write(&core, &card);
            } else if let Some(tag) = read_tag(&card, &mut last_scan) {
                core.record_scan(tag);
            }
        }

        // Expire a pending write whose deadline has passed
        {
            let mut slot = core.pending_write.lock().unwrap();
            if let Some(w) = slot.as_ref() {
                if Instant::now() > w.deadline {
                    if let Some(w) = slot.take() {
                        let _ = w.responder.send(Err(
                            "Timed out waiting for a tag. Ensure the tag is present and writable."
                                .into(),
                        ));
                    }
                }
            }
        }

        std::thread::sleep(POLL_INTERVAL);
    }
}

/// Returns reader names, or Err(true) when the PC/SC context must be rebuilt.
fn list_readers(ctx: &Context) -> Result<Vec<String>, bool> {
    let mut buf = [0u8; 4096];
    match ctx.list_readers(&mut buf) {
        Ok(iter) => Ok(iter
            .map(|r| r.to_string_lossy().into_owned())
            .filter(|n| !n.is_empty())
            .collect()),
        Err(PcscError::NoReadersAvailable) => Ok(Vec::new()),
        Err(PcscError::NoService | PcscError::ServiceStopped | PcscError::InvalidHandle) => {
            Err(true)
        }
        Err(_) => Err(false),
    }
}

fn read_tag(card: &Card, last_scan: &mut Option<(String, Instant)>) -> Option<TagData> {
    let uid = get_uid(card)?;

    let now = Instant::now();
    if let Some((prev_uid, at)) = last_scan {
        if *prev_uid == uid && now.duration_since(*at) < DEBOUNCE {
            return None;
        }
    }
    *last_scan = Some((uid.clone(), now));

    let parsed = read_ndef_raw(card).map(|raw| ndef::parse(&raw));

    Some(TagData {
        uid,
        ndef_url: parsed.as_ref().and_then(|p| p.url.clone()),
        ndef_text: parsed.as_ref().and_then(|p| p.text.clone()),
        attend_token: parsed.as_ref().and_then(|p| p.attend_token.clone()),
        raw_ndef: parsed.as_ref().map(|p| p.raw_hex.clone()),
        timestamp: Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
    })
}

fn transmit(card: &Card, apdu: &[u8]) -> Option<Vec<u8>> {
    let mut recv = [0u8; 264];
    let response = card.transmit(apdu, &mut recv).ok()?;
    if response.len() < 2 {
        return None;
    }
    let (data, sw) = response.split_at(response.len() - 2);
    if sw != [0x90, 0x00] {
        return None;
    }
    Some(data.to_vec())
}

fn get_uid(card: &Card) -> Option<String> {
    // PC/SC 2.01 standard "Get Data" — supported by virtually all CCID readers
    let data = transmit(card, &[0xFF, 0xCA, 0x00, 0x00, 0x00])?;
    if data.is_empty() {
        return None;
    }
    Some(
        data.iter()
            .map(|b| format!("{b:02X}"))
            .collect::<Vec<_>>()
            .join(":"),
    )
}

fn read_ndef_raw(card: &Card) -> Option<Vec<u8>> {
    let mut all = Vec::new();

    // Read blocks 4-39 (Type 2 tag data area; enough for most NDEF messages)
    for block in (0x04u8..0x28).step_by(4) {
        match transmit(card, &[0xFF, 0xB0, 0x00, block, 0x10]) {
            Some(data) if !data.is_empty() => all.extend(data),
            _ => break,
        }
    }

    if all.len() < 4 {
        return None;
    }

    // Find the NDEF TLV (0x03)
    let tlv_start = all.iter().position(|&b| b == 0x03)?;
    if tlv_start + 1 >= all.len() {
        return None;
    }
    let ndef_len = all[tlv_start + 1] as usize;
    let ndef_start = tlv_start + 2;
    if ndef_start + ndef_len > all.len() {
        return None;
    }

    Some(all[ndef_start..ndef_start + ndef_len].to_vec())
}

fn try_pending_write(core: &AppCore, card: &Card) {
    let (badge_url, attend_token) = {
        let slot = core.pending_write.lock().unwrap();
        match slot.as_ref() {
            Some(w) => (w.badge_url.clone(), w.attend_token.clone()),
            None => return,
        }
    };

    if write_ndef(card, &badge_url, attend_token.as_deref()) {
        if let Some(w) = core.pending_write.lock().unwrap().take() {
            let _ = w.responder.send(Ok(()));
        }
    }
}

fn write_ndef(card: &Card, badge_url: &str, attend_token: Option<&str>) -> bool {
    let msg = ndef::encode(badge_url, attend_token);
    if msg.len() > 0xFE {
        return false; // long-form TLV not supported (matches tag capacity anyway)
    }

    let mut tlv = vec![0x03, msg.len() as u8];
    tlv.extend(msg);
    tlv.push(0xFE);
    while tlv.len() % 4 != 0 {
        tlv.push(0x00);
    }

    let mut block = 0x04u8;
    for chunk in tlv.chunks(4) {
        if block >= 0x30 {
            return false;
        }
        let mut apdu = vec![0xFF, 0xD6, 0x00, block, 0x04];
        apdu.extend(chunk);
        apdu.resize(9, 0x00);
        if transmit(card, &apdu).is_none() {
            return false;
        }
        block += 1;
    }

    true
}
