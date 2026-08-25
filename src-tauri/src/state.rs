use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tauri::menu::MenuItem;
use tauri::{AppHandle, Emitter, Wry};
use tokio::sync::{broadcast, oneshot};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TagData {
    pub uid: String,
    pub ndef_url: Option<String>,
    pub ndef_text: Option<String>,
    pub attend_token: Option<String>,
    pub raw_ndef: Option<String>,
    pub timestamp: String,
}

#[derive(Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct BridgeState {
    pub enabled: bool,
    pub server_running: bool,
    pub server_error: Option<String>,
    pub reader_names: Vec<String>,
    pub connections: usize,
    pub last_scan: Option<TagData>,
}

pub struct PendingWrite {
    pub badge_url: String,
    pub attend_token: Option<String>,
    pub deadline: Instant,
    pub responder: oneshot::Sender<Result<(), String>>,
}

pub struct TrayItems {
    pub status: MenuItem<Wry>,
    pub reader: MenuItem<Wry>,
    pub connections: MenuItem<Wry>,
    pub toggle: MenuItem<Wry>,
}

#[derive(Clone)]
pub struct AppCore {
    pub state: Arc<Mutex<BridgeState>>,
    pub enabled: Arc<AtomicBool>,
    pub reconnect_requested: Arc<AtomicBool>,
    /// Outbound messages fanned out to every connected WebSocket client
    pub broadcast: broadcast::Sender<String>,
    /// Fired when the bridge is turned off; server + connection tasks exit
    pub shutdown: broadcast::Sender<()>,
    pub pending_write: Arc<Mutex<Option<PendingWrite>>>,
    pub app: Arc<Mutex<Option<AppHandle>>>,
    pub tray: Arc<Mutex<Option<TrayItems>>>,
}

impl AppCore {
    pub fn new() -> Self {
        let (broadcast, _) = broadcast::channel(64);
        let (shutdown, _) = broadcast::channel(4);
        AppCore {
            state: Arc::new(Mutex::new(BridgeState::default())),
            enabled: Arc::new(AtomicBool::new(false)),
            reconnect_requested: Arc::new(AtomicBool::new(false)),
            broadcast,
            shutdown,
            pending_write: Arc::new(Mutex::new(None)),
            app: Arc::new(Mutex::new(None)),
            tray: Arc::new(Mutex::new(None)),
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled.load(Ordering::SeqCst)
    }

    pub fn start(&self) {
        if self.is_enabled() {
            return;
        }
        self.enabled.store(true, Ordering::SeqCst);
        {
            let mut st = self.state.lock().unwrap();
            *st = BridgeState {
                enabled: true,
                ..BridgeState::default()
            };
        }
        crate::nfc::spawn_nfc_thread(self.clone());
        let core = self.clone();
        tauri::async_runtime::spawn(async move {
            crate::ws::run_server(core).await;
        });
        self.push_state();
    }

    pub fn stop(&self) {
        if !self.is_enabled() {
            return;
        }
        self.enabled.store(false, Ordering::SeqCst);
        let _ = self.shutdown.send(());
        if let Some(write) = self.pending_write.lock().unwrap().take() {
            let _ = write.responder.send(Err("Bridge turned off".into()));
        }
        {
            let mut st = self.state.lock().unwrap();
            *st = BridgeState::default();
        }
        self.push_state();
    }

    pub fn toggle(&self) {
        if self.is_enabled() {
            self.stop();
        } else {
            self.start();
        }
    }

    /// Sync UI (window event + tray menu) with the current state.
    pub fn push_state(&self) {
        let st = self.state.lock().unwrap().clone();

        if let Some(app) = self.app.lock().unwrap().as_ref() {
            let _ = app.emit("state", &st);
        }

        if let Some(tray) = self.tray.lock().unwrap().as_ref() {
            let status = if !st.enabled {
                "Status: Off".to_string()
            } else if let Some(err) = &st.server_error {
                format!("Status: Error — {err}")
            } else if st.server_running {
                "Status: Running on port 9876".to_string()
            } else {
                "Status: Starting...".to_string()
            };
            let reader = if !st.enabled {
                "Reader: —".to_string()
            } else if st.reader_names.is_empty() {
                "Reader: Not connected".to_string()
            } else {
                format!("Reader: {}", st.reader_names.join(", "))
            };
            let _ = tray.status.set_text(status);
            let _ = tray.reader.set_text(reader);
            let _ = tray
                .connections
                .set_text(format!("Connections: {}", st.connections));
            let _ = tray
                .toggle
                .set_text(if st.enabled { "Turn Off" } else { "Turn On" });
        }
    }

    pub fn set_reader_names(&self, names: Vec<String>) {
        let changed = {
            let mut st = self.state.lock().unwrap();
            if st.reader_names != names {
                st.reader_names = names;
                true
            } else {
                false
            }
        };
        if changed {
            self.push_state();
        }
    }

    pub fn record_scan(&self, tag: TagData) {
        {
            let mut st = self.state.lock().unwrap();
            st.last_scan = Some(tag.clone());
        }
        if let Ok(json) = serde_json::to_string(&tag) {
            let _ = self
                .broadcast
                .send(format!("{{\"type\":\"tag_read\",\"tag\":{json}}}"));
        }
        self.push_state();
    }
}
