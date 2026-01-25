import Foundation
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var server: WebSocketServer?
    var nfcReader: NFCReader?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        startServices()
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "wave.3.right.circle.fill", accessibilityDescription: "NFC Bridge")
        }
        
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
        
        menu.addItem(NSMenuItem(title: "Reconnect Reader", action: #selector(reconnectReader), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Copy WebSocket URL", action: #selector(copyWebSocketURL), keyEquivalent: "c"))
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    func startServices() {
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
    }
    
    func updateMenuItem(tag: Int, title: String) {
        if let item = statusItem.menu?.item(withTag: tag) {
            item.title = title
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
            self.updateMenuItem(tag: 101, title: "Reader: \(name)")
            if let button = self.statusItem.button {
                button.image = NSImage(systemSymbolName: "wave.3.right.circle.fill", accessibilityDescription: "NFC Bridge - Connected")
                button.contentTintColor = .systemGreen
            }
        }
    }
    
    func nfcReaderDidDisconnect(_ reader: NFCReader) {
        DispatchQueue.main.async {
            self.updateMenuItem(tag: 101, title: "Reader: Disconnected")
            if let button = self.statusItem.button {
                button.image = NSImage(systemSymbolName: "wave.3.right.circle", accessibilityDescription: "NFC Bridge - Disconnected")
                button.contentTintColor = .systemGray
            }
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
