# Attend NFC Bridge

A cross-platform desktop app that bridges USB NFC readers to web browsers via WebSocket. Built with [Tauri](https://tauri.app) — runs on **macOS**, **Windows**, and **Linux**.

## Features

- Works with **any PC/SC-compatible USB NFC reader** (ACR122U, ACR1252U, ACR1552U, HID Omnikey, Identiv uTrust, SCL3711, and most others)
- Supports multiple readers plugged in at once
- Reads NDEF URLs, text records, and `hackclub.com:attend` tokens from NFC tags
- Writes NDEF records to NFC tags (Type 2: NTAG213/215/216 etc.)
- Exposes a local WebSocket server on `ws://localhost:9876`
- Status window + system tray icon with live reader detection
- On/off toggle — turning it off stops the server and reader polling
- Closing the window keeps the bridge running in the tray

## Download

Grab the installer for your platform from the [latest release](https://github.com/hackclub/attend-nfc/releases/latest):

| Platform | File |
|----------|------|
| macOS (Apple Silicon + Intel) | `.dmg` |
| Windows | `.msi` or `-setup.exe` |
| Linux | `.AppImage`, `.deb`, or `.rpm` |

### Platform notes

- **macOS**: no extra setup — PC/SC is built in.
- **Windows**: no extra setup — the Smart Card service (winscard) is built in.
- **Linux**: install and start the PC/SC daemon: `sudo apt install pcscd && sudo systemctl enable --now pcscd` (the `.deb` pulls it in automatically).

## Building from source

Requires [Rust](https://rustup.rs) and [Node.js](https://nodejs.org).

```bash
npm install
npx tauri build
```

Installers land in `src-tauri/target/release/bundle/`. For development with hot reload:

```bash
npx tauri dev
```

On Linux you'll also need the Tauri system dependencies plus `libpcsclite-dev` — see `.github/workflows/release.yml` for the full apt list.

## Releasing

Push a tag and GitHub Actions builds installers for all three platforms and attaches them to a draft release:

```bash
git tag v2.0.0
git push origin v2.0.0
```

Then review and publish the draft on the [releases page](https://github.com/hackclub/attend-nfc/releases).

## WebSocket Protocol

### Connection

Connect to `ws://localhost:9876`

On connect, you'll receive:
```json
{"type":"connected","message":"Attend NFC Bridge connected","version":"2.0.0"}
```

### Incoming Messages (from bridge)

#### Tag Read
When an NFC tag is scanned:
```json
{
  "type": "tag_read",
  "tag": {
    "uid": "04:A1:B2:C3:D4:E5:F6",
    "ndefUrl": "https://attend.hackclub.com/nfc/abc123-uuid",
    "ndefText": null,
    "attendToken": "abc123",
    "rawNdef": "D10106...",
    "timestamp": "2025-01-23T12:34:56.789Z"
  }
}
```

#### Write Result
After a write request:
```json
{"type":"write_result","success":true,"badge_url":"https://attend.hackclub.com/nfc/abc123-uuid"}
```

Or on failure:
```json
{"type":"write_result","success":false,"error":"Failed to write to NFC tag. Ensure tag is present and writable."}
```

#### Write Pending
When waiting for tag:
```json
{"type":"write_pending","message":"Present NFC tag to write..."}
```

### Outgoing Messages (to bridge)

#### Ping
```json
{"action":"ping"}
```

Response:
```json
{"type":"pong","timestamp":"2025-01-23T12:34:56Z"}
```

#### Write
```json
{"action":"write","badge_url":"https://attend.hackclub.com/nfc/abc123-uuid","attend_token":"abc123"}
```

(`url` is accepted as a legacy alias for `badge_url`; `attend_token` is optional.)

#### Get Status
```json
{"action":"status"}
```

Response:
```json
{"type":"status","readerConnected":true,"readerName":"ACS ACR1552"}
```

## Web Integration

Example JavaScript for connecting from the browser:

```javascript
class AttendNFCBridge {
  constructor(onTagRead) {
    this.ws = null;
    this.onTagRead = onTagRead;
    this.pendingWriteResolve = null;
  }

  connect() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket('ws://localhost:9876');

      this.ws.onopen = () => resolve();
      this.ws.onerror = (e) => reject(e);

      this.ws.onmessage = (event) => {
        const data = JSON.parse(event.data);

        switch (data.type) {
          case 'tag_read':
            this.onTagRead(data.tag);
            break;
          case 'write_result':
            if (this.pendingWriteResolve) {
              this.pendingWriteResolve(data);
              this.pendingWriteResolve = null;
            }
            break;
        }
      };
    });
  }

  writeUrl(url) {
    return new Promise((resolve) => {
      this.pendingWriteResolve = resolve;
      this.ws.send(JSON.stringify({ action: 'write', badge_url: url }));
    });
  }

  disconnect() {
    this.ws?.close();
  }
}

// Usage in Attend scanner page:
const bridge = new AttendNFCBridge((tag) => {
  console.log('Tag scanned:', tag);
  if (tag.attendToken) {
    // Submit scan with badge_token...
  } else if (tag.ndefUrl?.includes('/nfc/')) {
    const token = tag.ndefUrl.split('/nfc/')[1];
    // Submit scan with badge_token...
  }
});

await bridge.connect();
```

## Security Notes

- The WebSocket server only binds to `127.0.0.1` (localhost)
- No external network access is possible
- The bridge does not store any data

## Troubleshooting

### Reader not detected
1. Ensure the USB reader is connected
2. On Linux, check pcscd is running: `systemctl status pcscd`
3. Try unplugging and reconnecting the reader
4. Click "Reconnect Reader" in the app

### Cannot write to tag
1. Ensure the tag is NFC Type 2 (NTAG213/215/216) or similar
2. Check the tag is not write-protected
3. Hold the tag steady on the reader during write

### WebSocket connection fails
1. Make sure the bridge is running (check the tray icon) and turned on
2. Check if another app is using port 9876
3. Try restarting the bridge app
