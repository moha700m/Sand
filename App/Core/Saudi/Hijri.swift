import Foundation

/// Umm al-Qura (official Saudi) Hijri calendar helpers.
public enum Hijri {
    public static let riyadh = TimeZone(identifier: "Asia/Riyadh")!

    public static var calendar: Calendar {
        var c = Calendar(identifier: .islamicUmmAlQura)
        c.timeZone = riyadh
        c.locale = Locale(identifier: "ar_SA")
        return c
    }

    public static var gregorian: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = riyadh
        return c
    }

    public static let monthNames = [
        "محرم", "صفر", "ربيع الأول", "ربيع الآخر", "جمادى الأولى", "جمادى الآخرة",
        "رجب", "شعبان", "رمضان", "شوال", "ذو القعدة", "ذو الحجة",
    ]

    public static let gregorianMonthNames = [
        "يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو",
        "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر",
    ]

    public static let weekdayNames = ["الأحد", "الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"]

    public struct DateParts: Equatable, Sendable {
        public var year: Int, month: Int, day: Int
        public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }
    }

    public static func hijriParts(from date: Date) -> DateParts {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return DateParts(year: c.year!, month: c.month!, day: c.day!)
    }

    public static func gregorianParts(from date: Date) -> DateParts {
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        return DateParts(year: c.year!, month: c.month!, day: c.day!)
    }

    public static func date(hijri p: DateParts) -> Date? {
        calendar.date(from: DateComponents(year: p.year, month: p.month, day: p.day, hour: 12))
    }

    public static func date(gregorian p: DateParts) -> Date? {
        gregorian.date(from: DateComponents(year: p.year, month: p.month, day: p.day, hour: 12))
    }

    public static func toHijri(_ g: DateParts) -> DateParts? {
        date(gregorian: g).map(hijriParts(from:))
    }

    public static func toGregorian(_ h: DateParts) -> DateParts? {
        date(hijri: h).map(gregorianParts(from:))
    }

    public static func describe(_ date: Date) -> String {
        let h = hijriParts(from: date)
        let g = gregorianParts(from: date)
        let wd = gregorian.component(.weekday, from: date) - 1
        return "\(weekdayNames[wd]) \(h.day) \(monthNames[h.month - 1]) \(h.year)هـ — الموافق \(g.day) \(gregorianMonthNames[g.month - 1]) \(g.year)م"
    }

    /// Parses "1447-09-01" or "2026/3/11" style dates.
    public static func parse(_ s: String) -> DateParts? {
        let digits = s.applyingArabicDigits()
        let parts = digits.split(whereSeparator: { "-/. ".contains($0) }).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        if parts[0] > 31 { return DateParts(year: parts[0], month: parts[1], day: parts[2]) }
        return DateParts(year: parts[2], month: parts[1], day: parts[0])
    }
}

public extension String {
    /// Converts Arabic-Indic and Persian digits to ASCII digits; Arabic decimal/thousands marks too.
    func applyingArabicDigits() -> String {
        var out = ""
        for ch in self {
            switch ch {
            case "٠"..."٩":
                out.append(Character(UnicodeScalar(ch.unicodeScalars.first!.value - 0x0660 + 48)!))
            case "۰"..."۹":
                out.append(Character(UnicodeScalar(ch.unicodeScalars.first!.value - 0x06F0 + 48)!))
            case "٫": out.append(".")
            case "٬": break
            case "×": out.append("*")
            case "÷": out.append("/")
            default: out.append(ch)
            }
        }
        return out
    }
}
