# Attend NFC Bridge

A macOS menu bar app that bridges USB NFC readers (like ACR1552) to web browsers via WebSocket.

## Features

- Connects to USB NFC readers via PC/SC (CCID) protocol
- Reads NDEF URLs and text records from NFC tags
- Writes NDEF URL records to NFC tags
- Exposes a local WebSocket server on `ws://localhost:9876`
- Menu bar status indicator with connection info

## Supported Readers

- ACR1552 and other ACR series readers
- Any PC/SC compatible NFC reader

## Building

```bash
./build.sh
```

Or manually:

```bash
swift build -c release
```

The binary will be at `.build/release/AttendNFCBridge`.

## Running

```bash
.build/release/AttendNFCBridge
```

The app will appear in your menu bar with an NFC icon. It shows:
- Server status (running on port 9876)
- Reader connection status
- Number of active WebSocket connections

## WebSocket Protocol

### Connection

Connect to `ws://localhost:9876`

On connect, you'll receive:
```json
{"type":"connected","message":"Attend NFC Bridge connected","version":"1.0.0"}
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
    "rawNdef": "D10106...",
    "timestamp": "2025-01-23T12:34:56Z"
  }
}
```

#### Write Result
After a write request:
```json
{"type":"write_result","success":true,"url":"https://attend.hackclub.com/nfc/abc123-uuid"}
```

Or on failure:
```json
{"type":"write_result","success":false,"error":"Failed to write to NFC tag"}
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

#### Write URL
```json
{"action":"write","url":"https://attend.hackclub.com/nfc/abc123-uuid"}
```

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
      this.ws.send(JSON.stringify({ action: 'write', url }));
    });
  }

  disconnect() {
    this.ws?.close();
  }
}

// Usage in Attend scanner page:
const bridge = new AttendNFCBridge((tag) => {
  console.log('Tag scanned:', tag);
  // Parse attend://nfc/{token} URLs
  if (tag.ndefUrl?.includes('/nfc/')) {
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
2. Check System Preferences > Privacy & Security for any blocks
3. Try unplugging and reconnecting the reader
4. Click "Reconnect Reader" in the menu bar

### Cannot write to tag
1. Ensure the tag is NFC Type 2 (NTAG213/215/216) or similar
2. Check the tag is not write-protected
3. Hold the tag steady on the reader during write

### WebSocket connection fails
1. Make sure the bridge app is running (check menu bar)
2. Check if another app is using port 9876
3. Try restarting the bridge app
