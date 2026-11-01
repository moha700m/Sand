import Foundation

/// One message from an exported chat (WhatsApp `.txt`).
public struct ArchiveMessage: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var date: Date?
    public var sender: String
    public var text: String
    public var isSystem: Bool

    public init(date: Date? = nil, sender: String, text: String, isSystem: Bool = false) {
        self.date = date
        self.sender = sender
        self.text = text
        self.isSystem = isSystem
    }

    public var isMedia: Bool {
        let t = text.lowercased()
        return t.contains("media omitted")
            || t.contains("image omitted")
            || t.contains("video omitted")
            || t.contains("audio omitted")
            || t.contains("sticker omitted")
            || t.contains("document omitted")
            || t.contains("تم حذف هذه الرسالة")
            || t.contains("هذه الرسالة حُذفت")
            || text == "صورة" || text == "فيديو" || text == "رسالة صوتية"
            || text == "ملصق" || text == "مستند" || text == "GIF"
    }
}

public struct ChatArchive: Sendable {
    public var title: String
    public var messages: [ArchiveMessage]
    public var participants: [String: Int]
    public var firstDate: Date?
    public var lastDate: Date?
    public var characterCount: Int

    public var messageCount: Int { messages.count }
    public var participantCount: Int { participants.count }

    public var topSenders: [(name: String, count: Int)] {
        participants.sorted { $0.value > $1.value }.prefix(4).map { ($0.key, $0.value) }
    }
}

/// Parses WhatsApp exports. Tolerant of iOS/Android formats, Arabic digits,
/// bidi marks, Arabic commas and multiline messages.
public enum ChatArchiveParser {

    // MARK: Parse

    public static func parse(_ raw: String, title: String = "محادثة") -> ChatArchive {
        let text = normalize(raw)
        var messages: [ArchiveMessage] = []
        var participants: [String: Int] = [:]
        var first: Date?
        var last: Date?
        var characters = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if let head = head(of: line) {
                let body = head.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty { continue }

                if let split = splitSender(body) {
                    let sender = split.sender
                    let content = split.text
                    guard !isSystemLine(sender: sender, text: content) else { continue }
                    let message = ArchiveMessage(date: head.date, sender: sender, text: content)
                    messages.append(message)
                    participants[sender, default: 0] += 1
                    characters += content.count
                    if let d = head.date {
                        if first == nil || d < first! { first = d }
                        if last == nil || d > last! { last = d }
                    }
                } else {
                    // Timestamped line without "sender: text" is a system notice.
                    continue
                }
            } else if var current = messages.popLast() {
                // Continuation of the previous message.
                current.text += "\n" + line
                characters += line.count
                messages.append(current)
            }
        }

        return ChatArchive(title: title, messages: messages, participants: participants,
                           firstDate: first, lastDate: last, characterCount: characters)
    }

    /// Cheap sanity check before parsing a picked file.
    public static func looksLikeExport(_ raw: String) -> Bool {
        let sample = String(normalize(raw).prefix(8000))
        let lines = sample.components(separatedBy: .newlines).prefix(80)
        var hits = 0
        for line in lines where head(of: line) != nil { hits += 1 }
        return hits >= 3
    }

    // MARK: Chunking

    /// Splits messages into readable chunks for small local context windows.
    public static func chunks(_ messages: [ArchiveMessage], maxCharacters: Int = 1700, maxMessages: Int = 90) -> [String] {
        var out: [String] = []
        var current: [String] = []
        var size = 0

        for m in messages where !m.isSystem {
            let line = "\(m.sender): \(m.isMedia ? "[وسائط]" : m.text)"
            if !current.isEmpty, size + line.count > maxCharacters || current.count >= maxMessages {
                out.append(current.joined(separator: "\n"))
                current = []
                size = 0
            }
            current.append(line)
            size += line.count + 1
        }
        if !current.isEmpty { out.append(current.joined(separator: "\n")) }
        return out
    }

    // MARK: Date range

    public static func dateLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ar_SA")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    // MARK: Internals

    struct Head {
        var date: Date?
        var body: String
    }

    static let linePattern = #"^\[?(\d{1,4}[/.\-]\d{1,2}[/.\-]\d{1,4})[,\s]+(\d{1,2}:\d{2}(?::\d{2})?)\s*([APap]\.?[Mm]\.?|ص|م)?\]?\s*[-–—]?\s*(.*)$"#

    static let lineRegex = try! NSRegularExpression(pattern: linePattern)

    static func head(of line: String) -> Head? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = lineRegex.firstMatch(in: line, range: range),
              let dateRange = Range(match.range(at: 1), in: line),
              let timeRange = Range(match.range(at: 2), in: line),
              let bodyRange = Range(match.range(at: 4), in: line) else { return nil }

        let dateText = String(line[dateRange])
        let timeText = String(line[timeRange])
        var meridiem = ""
        if match.range(at: 3).location != NSNotFound, let r = Range(match.range(at: 3), in: line) {
            meridiem = String(line[r]).uppercased()
        }
        return Head(date: parseDate(dateText, time: timeText, meridiem: meridiem),
                    body: String(line[bodyRange]))
    }

    static func splitSender(_ body: String) -> (sender: String, text: String)? {
        guard let range = body.range(of: ": ") else { return nil }
        let sender = String(body[body.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let text = String(body[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty, sender.count <= 60, !text.isEmpty else { return nil }
        return (sender, text)
    }

    static func isSystemLine(sender: String, text: String) -> Bool {
        let s = sender.lowercased()
        if s.contains("messages and calls are end-to-end encrypted") { return true }
        if sender.hasPrefix("+") && text.contains("changed") { return true }
        let t = text.lowercased()
        let markers = ["تم تشفير", "غيّر رقم", "غير رقم", "أضاف", "اضاف", "غادر", "انضم",
                       "أنشأ", "انشأ", "joined using this group", "changed the subject",
                       "changed this group", "added you", "removed you", "left"]
        return markers.contains { t.contains($0) || s.contains($0) }
    }

    static let dateFormatters: [DateFormatter] = {
        ["dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm",
         "MM/dd/yyyy HH:mm:ss", "MM/dd/yyyy HH:mm",
         "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm",
         "dd.MM.yyyy HH:mm:ss", "dd.MM.yyyy HH:mm",
         "dd-MM-yyyy HH:mm:ss", "dd-MM-yyyy HH:mm"].map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = format
            return f
        }
    }()

    static func parseDate(_ date: String, time: String, meridiem: String) -> Date? {
        let stamp = "\(date) \(time)"
        for f in dateFormatters {
            if let d = f.date(from: stamp) { return d }
        }
        return nil
    }

    /// Removes bidi/zero-width marks and converts Arabic-Indic digits and commas.
    public static func normalize(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF, 0x200B:
                continue
            case 0x0660...0x0669:
                out.unicodeScalars.append(UnicodeScalar(u.value - 0x0660 + 0x30)!)
            case 0x06F0...0x06F9:
                out.unicodeScalars.append(UnicodeScalar(u.value - 0x06F0 + 0x30)!)
            case 0x060C:
                out.unicodeScalars.append(",")
            case 0x066B:
                out.unicodeScalars.append(".")
            default:
                out.unicodeScalars.append(u)
            }
        }
        return out
    }
}
