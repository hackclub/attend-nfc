#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod ndef;
mod nfc;
mod state;
mod ws;

use state::{AppCore, BridgeState, TrayItems};
use std::sync::atomic::Ordering;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{Manager, WindowEvent};

#[tauri::command]
fn get_state(core: tauri::State<AppCore>) -> BridgeState {
    core.state.lock().unwrap().clone()
}

#[tauri::command]
fn toggle_bridge(core: tauri::State<AppCore>) {
    core.toggle();
}

#[tauri::command]
fn reconnect_reader(core: tauri::State<AppCore>) {
    core.reconnect_requested.store(true, Ordering::SeqCst);
}

fn show_main_window(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

fn main() {
    let core = AppCore::new();
    let core_for_setup = core.clone();

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            show_main_window(app);
        }))
        .manage(core.clone())
        .invoke_handler(tauri::generate_handler![
            get_state,
            toggle_bridge,
            reconnect_reader
        ])
        .on_window_event(|window, event| {
            // Closing the window keeps the bridge running in the tray
            if let WindowEvent::CloseRequested { api, .. } = event {
                let _ = window.hide();
                api.prevent_close();
            }
        })
        .setup(move |app| {
            let handle = app.handle().clone();
            *core_for_setup.app.lock().unwrap() = Some(handle.clone());

            let status = MenuItem::with_id(app, "status", "Status: Starting...", false, None::<&str>)?;
            let reader = MenuItem::with_id(app, "reader", "Reader: Not connected", false, None::<&str>)?;
            let connections = MenuItem::with_id(app, "connections", "Connections: 0", false, None::<&str>)?;
            let show = MenuItem::with_id(app, "show", "Show Window", true, None::<&str>)?;
            let toggle = MenuItem::with_id(app, "toggle", "Turn Off", true, None::<&str>)?;
            let reconnect = MenuItem::with_id(app, "reconnect", "Reconnect Reader", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;

            let menu = Menu::with_items(
                app,
                &[
                    &status,
                    &reader,
                    &connections,
                    &PredefinedMenuItem::separator(app)?,
                    &show,
                    &toggle,
                    &reconnect,
                    &PredefinedMenuItem::separator(app)?,
                    &quit,
                ],
            )?;

            *core_for_setup.tray.lock().unwrap() = Some(TrayItems {
                status,
                reader,
                connections,
                toggle: toggle.clone(),
            });

            let core_for_tray = core_for_setup.clone();
            TrayIconBuilder::with_id("main-tray")
                .icon(app.default_window_icon().unwrap().clone())
                .tooltip("Attend NFC Bridge")
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(move |app, event| match event.id.as_ref() {
                    "show" => show_main_window(app),
                    "toggle" => core_for_tray.toggle(),
                    "reconnect" => core_for_tray
                        .reconnect_requested
                        .store(true, Ordering::SeqCst),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;

            core_for_setup.start();
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| match event {
            // macOS: clicking the dock icon reopens the window
            tauri::RunEvent::Reopen { .. } => show_main_window(app),
            // Keep running in the tray when all windows are closed
            tauri::RunEvent::ExitRequested { api, code, .. } => {
                if code.is_none() {
                    api.prevent_exit();
                }
            }
            _ => {}
        });
}
