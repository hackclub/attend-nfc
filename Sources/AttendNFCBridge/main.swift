import Foundation
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var server: WebSocketServer?
    var nfcReader: NFCReader?
    var bridgeEnabled = false
    var readerConnected = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        startServices()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()

        let statusMenuItem = NSMenuItem(title: "Status: Starting...", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        menu.addItem(statusMenuItem)

        let readerMenuItem = NSMenuItem(title: "Reader: Not connected", action: nil, keyEquivalent: "")
        readerMenuItem.tag = 101
        menu.addItem(readerMenuItem)

        menu.addItem(NSMenuItem.separator())

        let connectionsMenuItem = NSMenuItem(title: "Connections: 0", action: nil, keyEquivalent: "")
        connectionsMenuItem.tag = 102
        menu.addItem(connectionsMenuItem)

        menu.addItem(NSMenuItem.separator())

        let toggleMenuItem = NSMenuItem(title: "Turn Off", action: #selector(toggleBridge), keyEquivalent: "t")
        toggleMenuItem.tag = 103
        menu.addItem(toggleMenuItem)

        menu.addItem(NSMenuItem(title: "Reconnect Reader", action: #selector(reconnectReader), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Copy WebSocket URL", action: #selector(copyWebSocketURL), keyEquivalent: "c"))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        updateIcon()
    }

    func startServices() {
        bridgeEnabled = true
        readerConnected = false

        nfcReader = NFCReader()
        nfcReader?.delegate = self
        nfcReader?.start()

        server = WebSocketServer(port: 9876)
        server?.nfcReader = nfcReader
        server?.onConnectionCountChanged = { [weak self] count in
            DispatchQueue.main.async {
                self?.updateMenuItem(tag: 102, title: "Connections: \(count)")
            }
        }

        server?.start { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Failed to start server: \(error)")
                    self?.updateMenuItem(tag: 100, title: "Status: Error")
                } else {
                    self?.updateMenuItem(tag: 100, title: "Status: Running on port 9876")
                }
            }
        }

        updateMenuItem(tag: 101, title: "Reader: Searching...")
        updateMenuItem(tag: 103, title: "Turn Off")
        updateIcon()
    }

    func stopServices() {
        bridgeEnabled = false
        readerConnected = false

        nfcReader?.stop()
        nfcReader = nil

        server?.shutdown()
        server = nil

        updateMenuItem(tag: 100, title: "Status: Off")
        updateMenuItem(tag: 101, title: "Reader: —")
        updateMenuItem(tag: 102, title: "Connections: 0")
        updateMenuItem(tag: 103, title: "Turn On")
        updateIcon()
    }

    func updateIcon() {
        guard let button = statusItem.button else { return }

        if !bridgeEnabled {
            button.image = NSImage(systemSymbolName: "wave.3.right.circle", accessibilityDescription: "NFC Bridge - Off")
            button.contentTintColor = .systemGray
        } else if readerConnected {
            button.image = NSImage(systemSymbolName: "wave.3.right.circle.fill", accessibilityDescription: "NFC Bridge - Reader connected")
            button.contentTintColor = .systemGreen
        } else {
            button.image = NSImage(systemSymbolName: "wave.3.right.circle.fill", accessibilityDescription: "NFC Bridge - No reader")
            button.contentTintColor = .systemOrange
        }
    }

    func updateMenuItem(tag: Int, title: String) {
        if let item = statusItem.menu?.item(withTag: tag) {
            item.title = title
        }
    }

    @objc func toggleBridge() {
        if bridgeEnabled {
            stopServices()
        } else {
            startServices()
        }
    }

    @objc func reconnectReader() {
        nfcReader?.reconnect()
    }

    @objc func copyWebSocketURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("ws://localhost:9876", forType: .string)
    }
}

extension AppDelegate: NFCReaderDelegate {
    func nfcReaderDidConnect(_ reader: NFCReader, name: String) {
        DispatchQueue.main.async {
            self.readerConnected = true
            self.updateMenuItem(tag: 101, title: "Reader: \(name)")
            self.updateIcon()
        }
    }

    func nfcReaderDidDisconnect(_ reader: NFCReader) {
        DispatchQueue.main.async {
            self.readerConnected = false
            if self.bridgeEnabled {
                self.updateMenuItem(tag: 101, title: "Reader: Not connected")
            }
            self.updateIcon()
        }
    }

    func nfcReader(_ reader: NFCReader, didReadTag data: TagData) {
        server?.broadcastTagRead(data)
    }

    func nfcReader(_ reader: NFCReader, didEncounterError error: String) {
        print("NFC Error: \(error)")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
