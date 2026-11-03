import Foundation

/// Reads a Finder `.DS_Store` file: a buddy-allocated file holding a B-tree of records keyed by
/// file name and a four-character code (`Iloc`, `icvp`, `bwsp` …). Never traps on damaged input:
/// anything out of bounds ends the read (what was read so far is kept).
struct DSStore {
    enum Value {
        case long(UInt32)
        case shor(UInt32)
        case bool(Bool)
        case blob(Data)
        case type(String)
        case ustr(String)
        case comp(UInt64)
        case dutc(UInt64)

        var blob: Data? {
            if case .blob(let data) = self { return data }
            return nil
        }

        var integer: Int? {
            switch self {
            case .long(let value), .shor(let value): return Int(value)
            case .comp(let value), .dutc(let value): return Int(truncatingIfNeeded: value)
            case .bool(let value): return value ? 1 : 0
            default: return nil
            }
        }
    }

    struct Record {
        let filename: String
        let code: String
        let value: Value
    }

    let records: [Record]

    static let maximumFileSize = 32 * 1024 * 1024
    private static let maximumRecords = 200_000
    private static let maximumDepth = 32

    init(records: [Record]) {
        self.records = records
    }

    init?(contentsOf url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= Self.maximumFileSize,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        guard let records = Self.parse(data) else { return nil }
        self.records = records
    }

    /// The value recorded for `filename` (`"."` is the folder itself) under `code`.
    func value(_ code: String, for filename: String = ".") -> Value? {
        records.first { $0.code == code && $0.filename == filename }?.value
    }

    /// The binary property list stored in a blob record (`icvp`, `bwsp`, `lsvp` …).
    func plist(_ code: String, for filename: String = ".") -> [String: Any]? {
        guard let data = value(code, for: filename)?.blob,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return plist as? [String: Any]
    }

    // MARK: - Parsing

    private struct Reader {
        let bytes: [UInt8]
        var offset: Int

        mutating func u8() -> UInt8? {
            guard offset >= 0, offset < bytes.count else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func u32() -> UInt32? {
            guard offset >= 0, offset <= bytes.count - 4 else { return nil }
            defer { offset += 4 }
            return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }

        mutating func u64() -> UInt64? {
            guard let high = u32(), let low = u32() else { return nil }
            return UInt64(high) << 32 | UInt64(low)
        }

        mutating func data(_ count: Int) -> Data? {
            guard count >= 0, offset >= 0, count <= bytes.count - offset else { return nil }
            defer { offset += count }
            return Data(bytes[offset..<offset + count])
        }

        mutating func fourCC() -> String? {
            guard let data = data(4) else { return nil }
            return String(data: data, encoding: .macOSRoman)
        }

        mutating func utf16(_ count: Int) -> String? {
            guard count >= 0, count <= 0x10000, let data = data(count * 2) else { return nil }
            return String(data: data, encoding: .utf16BigEndian)
        }
    }

    private static func parse(_ data: Data) -> [Record]? {
        let bytes = [UInt8](data)
        var header = Reader(bytes: bytes, offset: 0)
        // Magic: 0x00000001 'Bud1'; offsets that follow are from byte 4.
        guard header.u32() == 1, header.u32() == 0x4275_6431,
              let rootOffset = header.u32(), let rootSize = header.u32(), header.u32() == rootOffset,
              rootSize > 0 else { return nil }

        var root = Reader(bytes: bytes, offset: Int(rootOffset) + 4)
        guard let blockCount = root.u32(), blockCount < 1_000_000, root.u32() != nil else { return nil }
        var addresses: [UInt32] = []
        for _ in 0..<blockCount {
            guard let address = root.u32() else { return nil }
            addresses.append(address)
        }
        // The address table is padded to a multiple of 256 entries.
        let padded = (Int(blockCount) + 255) / 256 * 256
        root.offset += (padded - Int(blockCount)) * 4

        guard let tocCount = root.u32(), tocCount < 10_000 else { return nil }
        var dsdbBlock: UInt32?
        for _ in 0..<tocCount {
            guard let length = root.u8(), let nameData = root.data(Int(length)), let block = root.u32() else { return nil }
            if String(data: nameData, encoding: .ascii) == "DSDB" {
                dsdbBlock = block
            }
        }

        func blockReader(_ id: UInt32) -> Reader? {
            guard id < addresses.count else { return nil }
            let address = addresses[Int(id)]
            let offset = Int(address & ~0x1f) + 4
            let size = 1 << Int(address & 0x1f)
            guard offset >= 4, offset < bytes.count, size > 0, size <= bytes.count else { return nil }
            return Reader(bytes: bytes, offset: offset)
        }

        guard let dsdbBlock, var dsdb = blockReader(dsdbBlock), let rootNode = dsdb.u32() else { return nil }

        var records: [Record] = []
        var visited = Set<UInt32>()

        func readNode(_ id: UInt32, depth: Int) {
            guard depth < maximumDepth, records.count < maximumRecords,
                  visited.insert(id).inserted, var node = blockReader(id),
                  let next = node.u32(), let count = node.u32(), count < 100_000 else { return }
            if next == 0 {
                for _ in 0..<count {
                    guard let record = readRecord(&node) else { return }
                    records.append(record)
                }
            } else {
                for _ in 0..<count {
                    guard let child = node.u32() else { return }
                    readNode(child, depth: depth + 1)
                    guard let record = readRecord(&node) else { return }
                    records.append(record)
                }
                readNode(next, depth: depth + 1)
            }
        }

        readNode(rootNode, depth: 0)
        return records
    }

    private static func readRecord(_ reader: inout Reader) -> Record? {
        guard let nameLength = reader.u32(), let filename = reader.utf16(Int(nameLength)),
              let code = reader.fourCC(), let type = reader.fourCC() else { return nil }
        let value: Value
        switch type {
        case "long": guard let v = reader.u32() else { return nil }; value = .long(v)
        case "shor": guard let v = reader.u32() else { return nil }; value = .shor(v)
        case "bool": guard let v = reader.u8() else { return nil }; value = .bool(v != 0)
        case "type": guard let v = reader.fourCC() else { return nil }; value = .type(v)
        case "comp": guard let v = reader.u64() else { return nil }; value = .comp(v)
        case "dutc": guard let v = reader.u64() else { return nil }; value = .dutc(v)
        case "blob":
            guard let length = reader.u32(), let data = reader.data(Int(length)) else { return nil }
            value = .blob(data)
        case "ustr":
            guard let length = reader.u32(), let string = reader.utf16(Int(length)) else { return nil }
            value = .ustr(string)
        default:
            return nil
        }
        return Record(filename: filename, code: code, value: value)
    }
}

// MARK: - Alias records

/// The parts of a classic Alias Manager record (as stored in `icvp`'s `backgroundImageAlias`)
/// needed to find its target again on a volume mounted under another name.
enum AliasRecordPaths {
    /// The target's POSIX path relative to its volume ("/.background/bg.png"), from the record's
    /// extra info, or else from its Carbon path ("Volume:.background:bg.png").
    static func volumeRelativePath(from alias: Data) -> String? {
        let bytes = [UInt8](alias)
        // Fixed part: 150 bytes, then tagged items (Int16 tag, UInt16 length, data padded to even).
        var offset = 150
        var carbonPath: String?
        while offset + 4 <= bytes.count {
            let tag = Int16(bitPattern: UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
            let length = Int(UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3]))
            offset += 4
            guard tag != -1, offset + length <= bytes.count else { break }
            let data = Data(bytes[offset..<offset + length])
            if tag == 18, let path = String(data: data, encoding: .utf8), !path.isEmpty {
                return path.hasPrefix("/") ? path : "/" + path
            }
            if tag == 2 {
                carbonPath = String(data: data, encoding: .macOSRoman)
            }
            offset += length + (length & 1)
        }
        guard let carbonPath else { return nil }
        let parts = carbonPath.split(separator: ":", omittingEmptySubsequences: false).dropFirst()
        guard !parts.isEmpty else { return nil }
        // Carbon paths use ":" where POSIX names have "/".
        return "/" + parts.map { $0.replacingOccurrences(of: "/", with: ":") }.joined(separator: "/")
    }
}
