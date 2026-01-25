import Foundation
import CPCSCShim

struct TagData: Codable {
    let uid: String
    let ndefUrl: String?
    let ndefText: String?
    let attendToken: String?
    let rawNdef: String?
    let timestamp: Date
}

protocol NFCReaderDelegate: AnyObject {
    func nfcReaderDidConnect(_ reader: NFCReader, name: String)
    func nfcReaderDidDisconnect(_ reader: NFCReader)
    func nfcReader(_ reader: NFCReader, didReadTag data: TagData)
    func nfcReader(_ reader: NFCReader, didEncounterError error: String)
}

class NFCReader {
    weak var delegate: NFCReaderDelegate?
    
    private var context: UInt32 = 0
    private var card: UInt32 = 0
    private var activeProtocol: UInt32 = 0
    private var isRunning = false
    private(set) var readerName: String?
    private var lastUID: String?
    private var lastReadTime: Date?
    private var isWriting = false
    private let writeLock = NSLock()
    
    private let debounceInterval: TimeInterval = 1.5
    private let pollQueue = DispatchQueue(label: "nfc-poll-queue")
    private var pollWorkItem: DispatchWorkItem?
    
    func start() {
        isRunning = true
        connectToReader()
        schedulePoll()
    }
    
    private func schedulePoll() {
        guard isRunning else { return }
        
        pollWorkItem = DispatchWorkItem { [weak self] in
            self?.pollForCard()
            self?.schedulePoll()
        }
        
        pollQueue.asyncAfter(deadline: .now() + 0.3, execute: pollWorkItem!)
    }
    
    func stop() {
        isRunning = false
        pollWorkItem?.cancel()
        pollWorkItem = nil
        disconnect()
    }
    
    func reconnect() {
        disconnect()
        connectToReader()
    }
    
    private func connectToReader() {
        let result = pcsc_establish_context(&context)
        guard result == PCSC_SUCCESS else {
            delegate?.nfcReader(self, didEncounterError: "Failed to establish PC/SC context")
            return
        }
        
        var readersLen: UInt32 = 256
        var readers = [CChar](repeating: 0, count: Int(readersLen))
        
        let listResult = pcsc_list_readers(context, &readers, &readersLen)
        guard listResult == PCSC_SUCCESS, readersLen > 0 else {
            delegate?.nfcReaderDidDisconnect(self)
            return
        }
        
        let readerName = String(cString: readers)
        
        if !readerName.isEmpty {
            self.readerName = readerName
            delegate?.nfcReaderDidConnect(self, name: readerName)
        } else {
            delegate?.nfcReaderDidDisconnect(self)
        }
    }
    
    private func disconnect() {
        if card != 0 {
            pcsc_disconnect(card, 0)
            card = 0
        }
        if context != 0 {
            pcsc_release_context(context)
            context = 0
        }
        readerName = nil
        lastUID = nil
    }
    
    private func pollForCard() {
        // Reconnect context if needed
        if context == 0 {
            connectToReader()
        }
        
        guard isRunning, context != 0, let currentReader = readerName else {
            return
        }
        
        // Don't poll while writing
        guard !isWriting else { return }
        
        // Always ensure card is disconnected before connecting
        if card != 0 {
            pcsc_disconnect(card, 0)
            card = 0
        }
        
        let result = pcsc_connect(context, currentReader, &card, &activeProtocol)
        
        guard result == PCSC_SUCCESS, card != 0 else {
            card = 0
            return
        }
        
        // Read UID first
        guard let uid = getCardUID() else {
            pcsc_disconnect(card, 0)
            card = 0
            return
        }
        
        let now = Date()
        let isDuplicate = (uid == lastUID) && (lastReadTime != nil) && (now.timeIntervalSince(lastReadTime!) < debounceInterval)
        
        if !isDuplicate {
            lastUID = uid
            lastReadTime = now
            
            let ndefData = readNDEF()
            
            let tagData = TagData(
                uid: uid,
                ndefUrl: ndefData?.url,
                ndefText: ndefData?.text,
                attendToken: ndefData?.attendToken,
                rawNdef: ndefData?.raw,
                timestamp: now
            )
            
            delegate?.nfcReader(self, didReadTag: tagData)
        }
        
        // Always disconnect after operation
        pcsc_disconnect(card, 0)
        card = 0
    }
    
    private func getCardUID() -> String? {
        let getUIDCommand: [UInt8] = [0xFF, 0xCA, 0x00, 0x00, 0x00]
        var response = [UInt8](repeating: 0, count: 64)
        var responseLen: UInt32 = UInt32(response.count)
        
        let result = pcsc_transmit(
            card,
            activeProtocol,
            getUIDCommand,
            UInt32(getUIDCommand.count),
            &response,
            &responseLen
        )
        
        guard result == PCSC_SUCCESS, responseLen >= 2 else { return nil }
        
        let sw1 = response[Int(responseLen) - 2]
        let sw2 = response[Int(responseLen) - 1]
        
        guard sw1 == 0x90 && sw2 == 0x00 else { return nil }
        
        let uidBytes = response[0..<Int(responseLen - 2)]
        return uidBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    
    private func readNDEF() -> (url: String?, text: String?, attendToken: String?, raw: String?)? {
        guard let rawData = readNDEFRaw() else { return nil }
        
        let rawHex = rawData.map { String(format: "%02X", $0) }.joined()
        
        var index = 0
        var url: String?
        var text: String?
        var attendToken: String?
        
        let attendTypeBytes = Array("hackclub.com:attend".utf8)
        
        while index < rawData.count - 3 {
            let tnf = rawData[index] & 0x07
            let sr = (rawData[index] & 0x10) != 0
            let il = (rawData[index] & 0x08) != 0
            
            index += 1
            guard index < rawData.count else { break }
            
            let typeLen = Int(rawData[index])
            index += 1
            guard index < rawData.count else { break }
            
            let payloadLen: Int
            if sr {
                payloadLen = Int(rawData[index])
                index += 1
            } else {
                guard index + 4 <= rawData.count else { break }
                payloadLen = Int(rawData[index]) << 24 | Int(rawData[index + 1]) << 16 | Int(rawData[index + 2]) << 8 | Int(rawData[index + 3])
                index += 4
            }
            
            if il {
                guard index < rawData.count else { break }
                index += Int(rawData[index]) + 1
            }
            
            guard index + typeLen <= rawData.count else { break }
            let typeData = Array(rawData[index..<(index + typeLen)])
            index += typeLen
            
            guard index + payloadLen <= rawData.count else { break }
            let payload = Array(rawData[index..<(index + payloadLen)])
            index += payloadLen
            
            if tnf == 0x01 {
                // Well-known type
                if typeData == [0x55] && payload.count > 0 {
                    url = decodeNDEFUri(payload)
                } else if typeData == [0x54] && payload.count > 0 {
                    text = decodeNDEFText(payload)
                }
            } else if tnf == 0x04 {
                // External type - check for hackclub.com:attend
                if typeData == attendTypeBytes {
                    attendToken = String(bytes: payload, encoding: .utf8)
                }
            }
        }
        
        return (url, text, attendToken, rawHex)
    }
    
    private func readNDEFRaw() -> [UInt8]? {
        var allData = [UInt8]()
        var response = [UInt8](repeating: 0, count: 20)
        var responseLen: UInt32 = UInt32(response.count)
        
        // Read blocks 4-39 (enough for most NDEF messages)
        // NTAG read command returns 16 bytes (4 blocks) starting from specified block
        for startBlock: UInt8 in stride(from: 0x04, to: 0x28, by: 4) {
            let readCommand: [UInt8] = [0xFF, 0xB0, 0x00, startBlock, 0x10]
            responseLen = UInt32(response.count)
            
            let result = pcsc_transmit(
                card,
                activeProtocol,
                readCommand,
                UInt32(readCommand.count),
                &response,
                &responseLen
            )
            
            guard result == PCSC_SUCCESS, responseLen > 2 else { break }
            
            let sw1 = response[Int(responseLen) - 2]
            let sw2 = response[Int(responseLen) - 1]
            guard sw1 == 0x90 && sw2 == 0x00 else { break }
            
            allData.append(contentsOf: response[0..<Int(responseLen - 2)])
        }
        
        guard allData.count >= 4 else { return nil }
        
        guard let tlvStart = allData.firstIndex(of: 0x03), tlvStart + 1 < allData.count else {
            return nil
        }
        
        let ndefLen = Int(allData[tlvStart + 1])
        let ndefStart = tlvStart + 2
        
        guard ndefStart + ndefLen <= allData.count else { return nil }
        
        return Array(allData[ndefStart..<(ndefStart + ndefLen)])
    }
    
    private func decodeNDEFUri(_ payload: [UInt8]) -> String? {
        guard payload.count > 0 else { return nil }
        
        let prefixes: [UInt8: String] = [
            0x00: "",
            0x01: "http://www.",
            0x02: "https://www.",
            0x03: "http://",
            0x04: "https://",
            0x05: "tel:",
            0x06: "mailto:",
        ]
        
        let prefixCode = payload[0]
        let prefix = prefixes[prefixCode] ?? ""
        let rest = String(bytes: payload[1...], encoding: .utf8) ?? ""
        
        return prefix + rest
    }
    
    private func decodeNDEFText(_ payload: [UInt8]) -> String? {
        guard payload.count > 1 else { return nil }
        
        let langCodeLen = Int(payload[0] & 0x3F)
        guard payload.count > langCodeLen + 1 else { return nil }
        
        return String(bytes: payload[(langCodeLen + 1)...], encoding: .utf8)
    }
    
    func writeNDEFUrl(_ url: String) -> Bool {
        return writeNDEFDual(badgeUrl: url, attendToken: nil)
    }
    
    func writeNDEFDual(badgeUrl: String, attendToken: String?) -> Bool {
        writeLock.lock()
        isWriting = true
        defer {
            isWriting = false
            writeLock.unlock()
        }
        
        guard context != 0, let currentReader = readerName else { return false }
        
        var writeCard: UInt32 = 0
        var writeProtocol: UInt32 = 0
        let connectResult = pcsc_connect(context, currentReader, &writeCard, &writeProtocol)
        
        guard connectResult == PCSC_SUCCESS, writeCard != 0 else { return false }
        
        defer {
            pcsc_disconnect(writeCard, 0)
        }
        
        let ndefMessage: [UInt8]
        if let token = attendToken {
            ndefMessage = encodeNDEFDual(badgeUrl: badgeUrl, attendToken: token)
        } else {
            ndefMessage = encodeNDEFUrl(badgeUrl)
        }
        
        var tlvData: [UInt8] = [0x03, UInt8(ndefMessage.count)]
        tlvData.append(contentsOf: ndefMessage)
        tlvData.append(0xFE)
        
        while tlvData.count % 4 != 0 {
            tlvData.append(0x00)
        }
        
        var block: UInt8 = 0x04
        var offset = 0
        
        while offset < tlvData.count && block < 0x30 {
            let chunkSize = min(4, tlvData.count - offset)
            var chunk = Array(tlvData[offset..<(offset + chunkSize)])
            while chunk.count < 4 {
                chunk.append(0x00)
            }
            
            var writeCommand: [UInt8] = [0xFF, 0xD6, 0x00, block, 0x04]
            writeCommand.append(contentsOf: chunk)
            
            var response = [UInt8](repeating: 0, count: 16)
            var responseLen: UInt32 = UInt32(response.count)
            
            let result = pcsc_transmit(
                writeCard,
                writeProtocol,
                writeCommand,
                UInt32(writeCommand.count),
                &response,
                &responseLen
            )
            
            guard result == PCSC_SUCCESS && responseLen >= 2 else { return false }
            
            let sw1 = response[Int(responseLen) - 2]
            let sw2 = response[Int(responseLen) - 1]
            guard sw1 == 0x90 && sw2 == 0x00 else { return false }
            
            offset += 4
            block += 1
        }
        
        return true
    }
    
    private func encodeNDEFUrl(_ url: String) -> [UInt8] {
        var prefixCode: UInt8 = 0x00
        var urlRest = url
        
        let prefixes: [(String, UInt8)] = [
            ("https://www.", 0x02),
            ("http://www.", 0x01),
            ("https://", 0x04),
            ("http://", 0x03),
            ("tel:", 0x05),
            ("mailto:", 0x06),
        ]
        
        for (prefix, code) in prefixes {
            if url.hasPrefix(prefix) {
                prefixCode = code
                urlRest = String(url.dropFirst(prefix.count))
                break
            }
        }
        
        var payload: [UInt8] = [prefixCode]
        payload.append(contentsOf: Array(urlRest.utf8))
        
        var record: [UInt8] = [
            0xD1,
            0x01,
            UInt8(payload.count),
            0x55,
        ]
        record.append(contentsOf: payload)
        
        return record
    }
    
    private func encodeNDEFDual(badgeUrl: String, attendToken: String) -> [UInt8] {
        // First record: URI (badge URL) - MB=1, ME=0
        let uriRecord = encodeNDEFUriRecord(badgeUrl, isFirst: true, isLast: false)
        
        // Second record: External type (attend token) - MB=0, ME=1
        let extRecord = encodeNDEFExternalRecord(type: "hackclub.com:attend", payload: attendToken, isFirst: false, isLast: true)
        
        return uriRecord + extRecord
    }
    
    private func encodeNDEFUriRecord(_ url: String, isFirst: Bool, isLast: Bool) -> [UInt8] {
        var prefixCode: UInt8 = 0x00
        var urlRest = url
        
        let prefixes: [(String, UInt8)] = [
            ("https://www.", 0x02),
            ("http://www.", 0x01),
            ("https://", 0x04),
            ("http://", 0x03),
            ("tel:", 0x05),
            ("mailto:", 0x06),
        ]
        
        for (prefix, code) in prefixes {
            if url.hasPrefix(prefix) {
                prefixCode = code
                urlRest = String(url.dropFirst(prefix.count))
                break
            }
        }
        
        var payload: [UInt8] = [prefixCode]
        payload.append(contentsOf: Array(urlRest.utf8))
        
        // Header: MB, ME, CF=0, SR=1, IL=0, TNF=0x01 (well-known)
        var header: UInt8 = 0x11  // SR=1, TNF=1
        if isFirst { header |= 0x80 }  // MB
        if isLast { header |= 0x40 }   // ME
        
        var record: [UInt8] = [
            header,
            0x01,  // Type length
            UInt8(payload.count),  // Payload length (SR)
            0x55,  // Type: 'U'
        ]
        record.append(contentsOf: payload)
        
        return record
    }
    
    private func encodeNDEFExternalRecord(type: String, payload: String, isFirst: Bool, isLast: Bool) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        let payloadBytes = Array(payload.utf8)
        
        // Header: MB, ME, CF=0, SR=1, IL=0, TNF=0x04 (external)
        var header: UInt8 = 0x14  // SR=1, TNF=4
        if isFirst { header |= 0x80 }  // MB
        if isLast { header |= 0x40 }   // ME
        
        var record: [UInt8] = [
            header,
            UInt8(typeBytes.count),
            UInt8(payloadBytes.count),
        ]
        record.append(contentsOf: typeBytes)
        record.append(contentsOf: payloadBytes)
        
        return record
    }
}
