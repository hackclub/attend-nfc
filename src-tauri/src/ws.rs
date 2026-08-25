//! Local WebSocket server on 127.0.0.1:9876. Protocol matches the original
//! bridge: tag_read broadcasts, ping/status/write actions.

use crate::state::{AppCore, PendingWrite};
use chrono::{SecondsFormat, Utc};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::time::{Duration, Instant};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio_tungstenite::tungstenite::Message;

const PORT: u16 = 9876;
const WRITE_TIMEOUT: Duration = Duration::from_secs(15);

pub async fn run_server(core: AppCore) {
    let listener = match TcpListener::bind(("127.0.0.1", PORT)).await {
        Ok(l) => l,
        Err(e) => {
            let mut st = core.state.lock().unwrap();
            st.server_error = Some(format!("Could not bind port {PORT}: {e}"));
            drop(st);
            core.push_state();
            return;
        }
    };

    {
        let mut st = core.state.lock().unwrap();
        st.server_running = true;
        st.server_error = None;
    }
    core.push_state();

    let mut shutdown = core.shutdown.subscribe();
    loop {
        tokio::select! {
            _ = shutdown.recv() => break,
            accepted = listener.accept() => {
                if let Ok((stream, _)) = accepted {
                    let core = core.clone();
                    tokio::spawn(async move {
                        let _ = handle_connection(core, stream).await;
                    });
                }
            }
        }
    }
}

async fn handle_connection(core: AppCore, stream: TcpStream) -> Result<(), ()> {
    let ws = tokio_tungstenite::accept_async(stream).await.map_err(|_| ())?;
    let (mut sink, mut source) = ws.split();

    {
        let mut st = core.state.lock().unwrap();
        st.connections += 1;
    }
    core.push_state();

    let _ = sink
        .send(Message::text(format!(
            r#"{{"type":"connected","message":"Attend NFC Bridge connected","version":"{}"}}"#,
            env!("CARGO_PKG_VERSION")
        )))
        .await;

    let mut rx = core.broadcast.subscribe();
    let mut shutdown = core.shutdown.subscribe();

    loop {
        tokio::select! {
            _ = shutdown.recv() => {
                let _ = sink.close().await;
                break;
            }
            broadcast = rx.recv() => {
                match broadcast {
                    Ok(msg) => {
                        if sink.send(Message::text(msg)).await.is_err() {
                            break;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => break,
                }
            }
            incoming = source.next() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        handle_message(&core, &mut sink, text.as_str()).await;
                    }
                    Some(Ok(Message::Ping(data))) => {
                        let _ = sink.send(Message::Pong(data)).await;
                    }
                    Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                    _ => {}
                }
            }
        }
    }

    {
        let mut st = core.state.lock().unwrap();
        st.connections = st.connections.saturating_sub(1);
    }
    core.push_state();
    Ok(())
}

async fn handle_message<S>(core: &AppCore, sink: &mut S, text: &str)
where
    S: SinkExt<Message> + Unpin,
{
    let Ok(msg) = serde_json::from_str::<Value>(text) else {
        let _ = sink
            .send(Message::text(
                r#"{"type":"error","message":"Invalid message format"}"#,
            ))
            .await;
        return;
    };

    match msg.get("action").and_then(Value::as_str) {
        Some("ping") => {
            let reply = json!({
                "type": "pong",
                "timestamp": Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
            });
            let _ = sink.send(Message::text(reply.to_string())).await;
        }
        Some("status") => {
            let st = core.state.lock().unwrap().clone();
            let reply = json!({
                "type": "status",
                "readerConnected": !st.reader_names.is_empty(),
                "readerName": st.reader_names.first().cloned().unwrap_or_default(),
            });
            let _ = sink.send(Message::text(reply.to_string())).await;
        }
        Some("write") => {
            let badge_url = msg
                .get("badge_url")
                .or_else(|| msg.get("url"))
                .and_then(Value::as_str)
                .map(str::to_string);
            let attend_token = msg
                .get("attend_token")
                .and_then(Value::as_str)
                .map(str::to_string);

            let Some(badge_url) = badge_url else {
                let _ = sink.send(Message::text(
                    r#"{"type":"error","message":"Missing 'badge_url' or 'url' parameter for write action"}"#,
                )).await;
                return;
            };

            let (tx, rx) = oneshot::channel();
            let already_writing = {
                let mut slot = core.pending_write.lock().unwrap();
                if slot.is_some() {
                    true
                } else {
                    *slot = Some(PendingWrite {
                        badge_url: badge_url.clone(),
                        attend_token,
                        deadline: Instant::now() + WRITE_TIMEOUT,
                        responder: tx,
                    });
                    false
                }
            };
            if already_writing {
                let _ = sink.send(Message::text(
                    r#"{"type":"write_result","success":false,"error":"Another write is already in progress"}"#,
                )).await;
                return;
            }

            let _ = sink
                .send(Message::text(
                    r#"{"type":"write_pending","message":"Present NFC tag to write..."}"#,
                ))
                .await;

            let outcome = tokio::time::timeout(WRITE_TIMEOUT + Duration::from_secs(1), rx).await;
            let reply = match outcome {
                Ok(Ok(Ok(()))) => json!({
                    "type": "write_result",
                    "success": true,
                    "badge_url": badge_url,
                }),
                Ok(Ok(Err(err))) => json!({
                    "type": "write_result",
                    "success": false,
                    "error": err,
                }),
                _ => {
                    core.pending_write.lock().unwrap().take();
                    json!({
                        "type": "write_result",
                        "success": false,
                        "error": "Failed to write to NFC tag. Ensure tag is present and writable.",
                    })
                }
            };
            let _ = sink.send(Message::text(reply.to_string())).await;
        }
        Some(other) => {
            let reply = json!({"type": "error", "message": format!("Unknown action: {other}")});
            let _ = sink.send(Message::text(reply.to_string())).await;
        }
        None => {
            let _ = sink
                .send(Message::text(
                    r#"{"type":"error","message":"Invalid message format"}"#,
                ))
                .await;
        }
    }
}
