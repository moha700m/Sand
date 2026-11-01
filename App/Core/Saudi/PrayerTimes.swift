import Foundation

/// Offline prayer-time calculation using the Umm al-Qura method
/// (Fajr 18.5°, Isha 90 minutes after Maghrib — 120 in Ramadan, Asr standard shadow).
public struct PrayerTimes: Equatable, Sendable {
    public var fajr: Date, sunrise: Date, dhuhr: Date, asr: Date, maghrib: Date, isha: Date

    public struct City: Identifiable, Hashable, Sendable {
        public var id: String { name }
        public var name: String
        public var latitude: Double
        public var longitude: Double
        public init(name: String, latitude: Double, longitude: Double) {
            self.name = name; self.latitude = latitude; self.longitude = longitude
        }
    }

    public static let cities: [City] = [
        City(name: "الرياض", latitude: 24.7136, longitude: 46.6753),
        City(name: "مكة المكرمة", latitude: 21.4225, longitude: 39.8262),
        City(name: "المدينة المنورة", latitude: 24.4672, longitude: 39.6111),
        City(name: "جدة", latitude: 21.5433, longitude: 39.1728),
        City(name: "الدمام", latitude: 26.4207, longitude: 50.0888),
        City(name: "الخبر", latitude: 26.2172, longitude: 50.1971),
        City(name: "الطائف", latitude: 21.2703, longitude: 40.4158),
        City(name: "تبوك", latitude: 28.3835, longitude: 36.5662),
        City(name: "بريدة", latitude: 26.3260, longitude: 43.9750),
        City(name: "أبها", latitude: 18.2164, longitude: 42.5053),
        City(name: "حائل", latitude: 27.5114, longitude: 41.7208),
        City(name: "جازان", latitude: 16.8892, longitude: 42.5511),
        City(name: "نجران", latitude: 17.5656, longitude: 44.2289),
        City(name: "الأحساء", latitude: 25.3833, longitude: 49.5833),
        City(name: "الجوف (سكاكا)", latitude: 29.9697, longitude: 40.2064),
        City(name: "عرعر", latitude: 30.9753, longitude: 41.0381),
        City(name: "الباحة", latitude: 20.0129, longitude: 41.4677),
        City(name: "ينبع", latitude: 24.0895, longitude: 38.0618),
    ]

    public static func city(named name: String) -> City? {
        let n = ArabicText.normalize(name)
        return cities.first { ArabicText.normalize($0.name).contains(n) || n.contains(ArabicText.normalize($0.name)) }
    }

    public static func compute(date: Date, latitude: Double, longitude: Double,
                               timeZone: TimeZone = Hijri.riyadh) -> PrayerTimes {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let jd = julianDay(year: comps.year!, month: comps.month!, day: comps.day!) - longitude / (15 * 24)
        let tz = Double(timeZone.secondsFromGMT(for: date)) / 3600

        func sunPosition(_ t: Double) -> (decl: Double, eqt: Double) {
            let d = jd + t - 2451545.0
            let g = fixAngle(357.529 + 0.98560028 * d)
            let q = fixAngle(280.459 + 0.98564736 * d)
            let l = fixAngle(q + 1.915 * dsin(g) + 0.020 * dsin(2 * g))
            let e = 23.439 - 0.00000036 * d
            let ra = darctan2(dcos(e) * dsin(l), dcos(l)) / 15
            let eqt = q / 15 - fixHour(ra)
            let decl = darcsin(dsin(e) * dsin(l))
            return (decl, eqt)
        }
        func midDay(_ t: Double) -> Double { fixHour(12 - sunPosition(t).eqt) }
        func sunAngleTime(_ angle: Double, _ t: Double, ccw: Bool) -> Double {
            let decl = sunPosition(t).decl
            let noon = midDay(t)
            let v = (-dsin(angle) - dsin(decl) * dsin(latitude)) / (dcos(decl) * dcos(latitude))
            let tt = darccos(max(-1, min(1, v))) / 15
            return noon + (ccw ? -tt : tt)
        }
        func asrTime(_ factor: Double, _ t: Double) -> Double {
            let decl = sunPosition(t).decl
            let angle = -darccot(factor + dtan(abs(latitude - decl)))
            return sunAngleTime(angle, t, ccw: false)
        }

        // Initial guesses as day portions
        let fajrH = sunAngleTime(18.5, 5.0 / 24, ccw: true)
        let sunriseH = sunAngleTime(0.833, 6.0 / 24, ccw: true)
        let dhuhrH = midDay(12.0 / 24)
        let asrH = asrTime(1, 13.0 / 24)
        let maghribH = sunAngleTime(0.833, 18.0 / 24, ccw: false)
        let isRamadan = Hijri.hijriParts(from: date).month == 9
        let ishaH = maghribH + (isRamadan ? 2.0 : 1.5)

        let adjust = tz - longitude / 15
        let base = cal.startOfDay(for: date)
        func toDate(_ h: Double, extraMinutes: Double = 0) -> Date {
            let hours = fixHour(h + adjust)
            return base.addingTimeInterval((hours * 3600 + extraMinutes * 60).rounded())
        }
        // Small safety offsets commonly applied (Dhuhr +1 min).
        return PrayerTimes(fajr: toDate(fajrH), sunrise: toDate(sunriseH), dhuhr: toDate(dhuhrH, extraMinutes: 1),
                           asr: toDate(asrH), maghrib: toDate(maghribH), isha: toDate(ishaH))
    }

    public var ordered: [(name: String, time: Date)] {
        [("الفجر", fajr), ("الشروق", sunrise), ("الظهر", dhuhr), ("العصر", asr), ("المغرب", maghrib), ("العشاء", isha)]
    }

    public func next(after date: Date) -> (name: String, time: Date)? {
        ordered.first { $0.time > date && $0.name != "الشروق" }
    }

    public func describe(timeZone: TimeZone = Hijri.riyadh) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ar_SA")
        f.timeZone = timeZone
        f.dateFormat = "h:mm a"
        return ordered.map { "\($0.name): \(f.string(from: $0.time))" }.joined(separator: "\n")
    }

    // MARK: - math helpers (degrees)
    static func julianDay(year: Int, month: Int, day: Int) -> Double {
        var y = year, m = month
        if m <= 2 { y -= 1; m += 12 }
        let a = floor(Double(y) / 100)
        let b = 2 - a + floor(a / 4)
        return floor(365.25 * Double(y + 4716)) + floor(30.6001 * Double(m + 1)) + Double(day) + b - 1524.5
    }
    static func dsin(_ d: Double) -> Double { sin(d * .pi / 180) }
    static func dcos(_ d: Double) -> Double { cos(d * .pi / 180) }
    static func dtan(_ d: Double) -> Double { tan(d * .pi / 180) }
    static func darcsin(_ x: Double) -> Double { asin(x) * 180 / .pi }
    static func darccos(_ x: Double) -> Double { acos(x) * 180 / .pi }
    static func darctan2(_ y: Double, _ x: Double) -> Double { atan2(y, x) * 180 / .pi }
    static func darccot(_ x: Double) -> Double { atan(1 / x) * 180 / .pi }
    static func fixAngle(_ a: Double) -> Double { let r = a.truncatingRemainder(dividingBy: 360); return r < 0 ? r + 360 : r }
    static func fixHour(_ a: Double) -> Double { let r = a.truncatingRemainder(dividingBy: 24); return r < 0 ? r + 24 : r }
}

public enum Qibla {
    public static let kaabaLatitude = 21.4225
    public static let kaabaLongitude = 39.8262

    /// Initial great-circle bearing from the given location to the Kaaba, degrees clockwise from true north.
    public static func bearing(latitude: Double, longitude: Double) -> Double {
        let phi1 = latitude * .pi / 180
        let phi2 = kaabaLatitude * .pi / 180
        let dLam = (kaabaLongitude - longitude) * .pi / 180
        let y = sin(dLam) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLam)
        let theta = atan2(y, x) * 180 / .pi
        return (theta + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Great-circle distance to the Kaaba in kilometres.
    public static func distanceKm(latitude: Double, longitude: Double) -> Double {
        let r = 6371.0
        let phi1 = latitude * .pi / 180, phi2 = kaabaLatitude * .pi / 180
        let dPhi = phi2 - phi1, dLam2 = (kaabaLongitude - longitude) * .pi / 180
        let a = sin(dPhi / 2) * sin(dPhi / 2) + cos(phi1) * cos(phi2) * sin(dLam2 / 2) * sin(dLam2 / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}
