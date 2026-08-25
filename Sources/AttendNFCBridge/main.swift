import Foundation
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var window: NSWindow!
    var server: WebSocketServer?
    var nfcReader: NFCReader?

    var bridgeEnabled = false
    var readerConnected = false
    var readerName: String?
    var connectionCount = 0
    var serverError = false

    // Window controls
    let serverDot = NSTextField(labelWithString: "●")
    let serverLabel = NSTextField(labelWithString: "Starting...")
    let readerDot = NSTextField(labelWithString: "●")
    let readerLabel = NSTextField(labelWithString: "No reader connected")
    let connectionsLabel = NSTextField(labelWithString: "Browser connections: 0")
    let lastScanLabel = NSTextField(wrappingLabelWithString: "No tags scanned yet")
    var toggleButton: NSButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupMenuBar()
        setupWindow()
        startServices()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the bridge running in the menu bar when the window is closed
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    // MARK: - UI setup

    func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About Attend NFC Bridge", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Attend NFC Bridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
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

        menu.addItem(NSMenuItem(title: "Show Window", action: #selector(showWindow), keyEquivalent: "s"))

        let toggleMenuItem = NSMenuItem(title: "Turn Off", action: #selector(toggleBridge), keyEquivalent: "t")
        toggleMenuItem.tag = 103
        menu.addItem(toggleMenuItem)

        menu.addItem(NSMenuItem(title: "Reconnect Reader", action: #selector(reconnectReader), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Copy WebSocket URL", action: #selector(copyWebSocketURL), keyEquivalent: "c"))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Attend NFC Bridge"
        window.isReleasedWhenClosed = false
        window.center()

        let titleLabel = NSTextField(labelWithString: "Attend NFC Bridge")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)

        for dot in [serverDot, readerDot] {
            dot.font = NSFont.systemFont(ofSize: 13)
            dot.setContentHuggingPriority(.required, for: .horizontal)
        }
        for label in [serverLabel, readerLabel, connectionsLabel] {
            label.font = NSFont.systemFont(ofSize: 13)
        }
        lastScanLabel.font = NSFont.systemFont(ofSize: 12)
        lastScanLabel.textColor = .secondaryLabelColor
        lastScanLabel.preferredMaxLayoutWidth = 340

        let serverRow = NSStackView(views: [serverDot, serverLabel])
        serverRow.orientation = .horizontal
        serverRow.spacing = 6

        let readerRow = NSStackView(views: [readerDot, readerLabel])
        readerRow.orientation = .horizontal
        readerRow.spacing = 6

        let lastScanHeader = NSTextField(labelWithString: "Last scan")
        lastScanHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        lastScanHeader.textColor = .secondaryLabelColor

        toggleButton = NSButton(title: "Turn Off", target: self, action: #selector(toggleBridge))
        toggleButton.bezelStyle = .rounded
        toggleButton.keyEquivalent = "\r"

        let copyButton = NSButton(title: "Copy WebSocket URL", target: self, action: #selector(copyWebSocketURL))
        copyButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [toggleButton, copyButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [
            titleLabel,
            serverRow,
            readerRow,
            connectionsLabel,
            lastScanHeader,
            lastScanLabel,
            buttonRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: titleLabel)
        stack.setCustomSpacing(16, after: connectionsLabel)
        stack.setCustomSpacing(4, after: lastScanHeader)
        stack.setCustomSpacing(16, after: lastScanLabel)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = window.contentView!
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    // MARK: - Services

    func startServices() {
        bridgeEnabled = true
        readerConnected = false
        readerName = nil
        serverError = false

        nfcReader = NFCReader()
        nfcReader?.delegate = self
        nfcReader?.start()

        server = WebSocketServer(port: 9876)
        server?.nfcReader = nfcReader
        server?.onConnectionCountChanged = { [weak self] count in
            DispatchQueue.main.async {
                self?.connectionCount = count
                self?.refreshUI()
            }
        }

        server?.start { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Failed to start server: \(error)")
                    self?.serverError = true
                }
                self?.refreshUI()
            }
        }

        refreshUI()
    }

    func stopServices() {
        bridgeEnabled = false
        readerConnected = false
        readerName = nil
        connectionCount = 0
        serverError = false

        nfcReader?.stop()
        nfcReader = nil

        server?.shutdown()
        server = nil

        refreshUI()
    }

    // MARK: - UI state

    func refreshUI() {
        // Menu bar
        let statusTitle: String
        if !bridgeEnabled {
            statusTitle = "Status: Off"
        } else if serverError {
            statusTitle = "Status: Error"
        } else {
            statusTitle = "Status: Running on port 9876"
        }
        updateMenuItem(tag: 100, title: statusTitle)
        updateMenuItem(tag: 101, title: bridgeEnabled ? "Reader: \(readerName ?? "Not connected")" : "Reader: —")
        updateMenuItem(tag: 102, title: "Connections: \(connectionCount)")
        updateMenuItem(tag: 103, title: bridgeEnabled ? "Turn Off" : "Turn On")

        if let button = statusItem.button {
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

        // Window
        if !bridgeEnabled {
            serverDot.textColor = .systemGray
            serverLabel.stringValue = "Bridge is off"
            readerDot.textColor = .systemGray
            readerLabel.stringValue = "—"
        } else {
            if serverError {
                serverDot.textColor = .systemRed
                serverLabel.stringValue = "Server error — is port 9876 in use?"
            } else {
                serverDot.textColor = .systemGreen
                serverLabel.stringValue = "Running on ws://localhost:9876"
            }
            if readerConnected {
                readerDot.textColor = .systemGreen
                readerLabel.stringValue = readerName ?? "Reader connected"
            } else {
                readerDot.textColor = .systemOrange
                readerLabel.stringValue = "No reader connected — plug in your NFC reader"
            }
        }
        connectionsLabel.stringValue = "Browser connections: \(connectionCount)"
        toggleButton.title = bridgeEnabled ? "Turn Off" : "Turn On"
    }

    func updateMenuItem(tag: Int, title: String) {
        if let item = statusItem.menu?.item(withTag: tag) {
            item.title = title
        }
    }

    // MARK: - Actions

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
            self.readerName = name
            self.refreshUI()
        }
    }

    func nfcReaderDidDisconnect(_ reader: NFCReader) {
        DispatchQueue.main.async {
            self.readerConnected = false
            self.readerName = nil
            self.refreshUI()
        }
    }

    func nfcReader(_ reader: NFCReader, didReadTag data: TagData) {
        server?.broadcastTagRead(data)

        DispatchQueue.main.async {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            var lines = ["\(formatter.string(from: data.timestamp))  UID \(data.uid)"]
            if let url = data.ndefUrl { lines.append(url) }
            if let token = data.attendToken { lines.append("token: \(token)") }
            self.lastScanLabel.stringValue = lines.joined(separator: "\n")
        }
    }

    func nfcReader(_ reader: NFCReader, didEncounterError error: String) {
        print("NFC Error: \(error)")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
