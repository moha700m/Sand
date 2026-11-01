import Foundation

/// Minimal ZIP support: writes stored (uncompressed) archives and reads archives of the same kind.
/// Deliberately dependency-free; deflate is not implemented, so foreign archives are rejected
/// with an explicit error instead of being silently corrupted.
public enum ZipError: LocalizedError {
    case unsupported(String)
    case corrupt(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): return "أرشيف غير مدعوم: \(s)"
        case .corrupt(let s): return "أرشيف تالف: \(s)"
        case .empty: return "الأرشيف فارغ."
        }
    }
}

public enum ZipWriter {
    public static func write(entries: [(path: String, data: Data)], to url: URL, root: String? = nil) throws {
        guard !entries.isEmpty else { throw ZipError.empty }
        var out = Data()
        var central = Data()
        var offsets: [Int] = []

        for (path, data) in entries {
            let name = (root.map { $0 + "/" } ?? "") + sanitize(path)
            guard let nameData = name.data(using: .utf8) else { continue }
            let crc = CRC32.checksum(data)
            let (time, date) = dosTimestamp(Date())
            offsets.append(out.count)
            out.append(uint32: 0x0403_4b50)
            out.append(uint16: 20)               // version needed
            out.append(uint16: 0x0800)           // UTF-8 names
            out.append(uint16: 0)                // stored
            out.append(uint16: time)
            out.append(uint16: date)
            out.append(uint32: crc)
            out.append(uint32: UInt32(data.count))
            out.append(uint32: UInt32(data.count))
            out.append(uint16: UInt16(nameData.count))
            out.append(uint16: 0)                // extra
            out.append(nameData)
            out.append(data)

            central.append(uint32: 0x0201_4b50)
            central.append(uint16: 20)           // made by
            central.append(uint16: 20)           // needed
            central.append(uint16: 0x0800)
            central.append(uint16: 0)
            central.append(uint16: time)
            central.append(uint16: date)
            central.append(uint32: crc)
            central.append(uint32: UInt32(data.count))
            central.append(uint32: UInt32(data.count))
            central.append(uint16: UInt16(nameData.count))
            central.append(uint16: 0)            // extra
            central.append(uint16: 0)            // comment
            central.append(uint16: 0)            // disk
            central.append(uint16: 0)            // internal attrs
            central.append(uint32: UInt32(0o644 << 16))  // external attrs
            central.append(uint32: UInt32(offsets.last ?? 0))
            central.append(nameData)
        }

        let cdStart = out.count
        out.append(central)
        out.append(uint32: 0x0605_4b50)
        out.append(uint16: 0)                    // disk
        out.append(uint16: 0)                    // cd disk
        out.append(uint16: UInt16(entries.count))
        out.append(uint16: UInt16(entries.count))
        out.append(uint32: UInt32(central.count))
        out.append(uint32: UInt32(cdStart))
        out.append(uint16: 0)                    // comment

        try out.write(to: url, options: [.atomic])
    }

    static func sanitize(_ path: String) -> String {
        let parts = path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
        return parts.isEmpty ? "file" : parts.joined(separator: "/")
    }

    static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, c.year ?? 2024))
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | ((c.second ?? 0) / 2))
        let day = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

public enum ZipReader {
    /// Returns (path, contents) for every entry. Only stored entries are supported.
    public static func read(_ url: URL) throws -> [(path: String, data: Data)] {
        let data = try Data(contentsOf: url)
        guard data.count > 22 else { throw ZipError.corrupt("أصغر من ترويسة ZIP") }
        guard let eocd = findEOCD(data) else { throw ZipError.corrupt("لم أجد نهاية الفهرس") }

        func u16(_ o: Int) -> UInt16 { UInt16(data[o]) | UInt16(data[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(data[o]) | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24 }

        let count = Int(u16(eocd + 10))
        var offset = Int(u32(eocd + 16))
        var out: [(String, Data)] = []

        for _ in 0..<count {
            guard offset + 46 <= data.count, u32(offset) == 0x0201_4b50 else { throw ZipError.corrupt("فهرس مركزي غير متوقع") }
            let method = u16(offset + 10)
            let compSize = Int(u32(offset + 20))
            let nameLen = Int(u16(offset + 28))
            let extraLen = Int(u16(offset + 30))
            let commentLen = Int(u16(offset + 32))
            let localOffset = Int(u32(offset + 42))
            guard offset + 46 + nameLen <= data.count else { throw ZipError.corrupt("اسم ملف مقطوع") }
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLen))
            let name = String(decoding: nameData, as: UTF8.self)
            guard localOffset + 30 <= data.count, u32(localOffset) == 0x0403_4b50 else { throw ZipError.corrupt("ترويسة محلية غير متوقعة") }
            let lNameLen = Int(u16(localOffset + 26))
            let lExtraLen = Int(u16(localOffset + 28))
            let start = localOffset + 30 + lNameLen + lExtraLen
            guard start + compSize <= data.count else { throw ZipError.corrupt("بيانات مقطوعة في \(name)") }
            if method != 0 { throw ZipError.unsupported("طريقة الضغط \(method) — المدعوم هو store فقط") }
            out.append((name, data.subdata(in: start..<(start + compSize))))
            offset += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    static func findEOCD(_ data: Data) -> Int? {
        let minSize = 22
        guard data.count >= minSize else { return nil }
        let lower = max(0, data.count - 22 - 65_535)
        var i = data.count - minSize
        while i >= lower {
            if data[i] == 0x50, data[i + 1] == 0x4b, data[i + 2] == 0x05, data[i + 3] == 0x06 { return i }
            i -= 1
        }
        return nil
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF))
    }
    mutating func append(uint32 value: UInt32) {
        append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF)); append(UInt8((value >> 24) & 0xFF))
    }
}
