import Foundation

/// Saudi VAT (15%) helpers with exact decimal arithmetic.
public enum VAT {
    public static let rate: Decimal = 0.15

    public struct Breakdown: Equatable, Sendable {
        public var net: Decimal, vat: Decimal, gross: Decimal
    }

    /// Adds VAT to a net (pre-tax) amount.
    public static func add(to net: Decimal) -> Breakdown {
        let vat = round(net * rate)
        return Breakdown(net: round(net), vat: vat, gross: round(net) + vat)
    }

    /// Extracts VAT from a gross (tax-inclusive) amount.
    public static func extract(from gross: Decimal) -> Breakdown {
        let net = round(gross / (1 + rate))
        return Breakdown(net: net, vat: round(gross) - net, gross: round(gross))
    }
}

/// Zakat al-mal: 2.5% of zakatable wealth when it reaches the nisab (85 g of 24k gold) and a lunar year passes.
public enum Zakat {
    public static let rate: Decimal = 0.025
    public static let nisabGoldGrams: Decimal = 85
    public static let nisabSilverGrams: Decimal = 595

    public struct Input: Equatable, Sendable {
        public var cash: Decimal = 0
        public var goldGrams24k: Decimal = 0
        public var silverGrams: Decimal = 0
        public var tradeGoods: Decimal = 0
        public var receivables: Decimal = 0
        public var stocks: Decimal = 0
        public var debtsDue: Decimal = 0
        public var goldPricePerGram: Decimal = 0
        public var silverPricePerGram: Decimal = 0
        public init() {}
    }

    public struct Result: Equatable, Sendable {
        public var totalWealth: Decimal
        public var nisab: Decimal
        public var isDue: Bool
        public var zakat: Decimal
    }

    public static func compute(_ i: Input) -> Result {
        let total = i.cash + i.goldGrams24k * i.goldPricePerGram + i.silverGrams * i.silverPricePerGram
            + i.tradeGoods + i.receivables + i.stocks - i.debtsDue
        let nisab = nisabGoldGrams * i.goldPricePerGram
        let due = nisab > 0 ? total >= nisab : total > 0
        return Result(totalWealth: VAT.round(total), nisab: VAT.round(nisab), isDue: due,
                      zakat: due ? VAT.round(max(0, total) * rate) : 0)
    }
}

/// End-of-service gratuity per the Saudi Labor Law (Article 84/85), simplified.
public enum EndOfService {
    public enum Reason: String, CaseIterable, Sendable { case terminatedByEmployer, resignation }

    /// - Parameters:
    ///   - monthlyWage: last full wage (basic + housing + regular allowances).
    ///   - years: total service in years (fractions allowed).
    public static func compute(monthlyWage: Decimal, years: Decimal, reason: Reason) -> Decimal {
        guard years > 0, monthlyWage > 0 else { return 0 }
        let firstFive = min(years, 5)
        let rest = max(0, years - 5)
        let full = monthlyWage / 2 * firstFive + monthlyWage * rest
        switch reason {
        case .terminatedByEmployer:
            return VAT.round(full)
        case .resignation:
            if years < 2 { return 0 }
            if years < 5 { return VAT.round(full / 3) }
            if years < 10 { return VAT.round(full * 2 / 3) }
            return VAT.round(full)
        }
    }
}

public extension VAT {
    static func round(_ d: Decimal, scale: Int = 2) -> Decimal {
        var x = d, r = Decimal()
        NSDecimalRound(&r, &x, scale, .plain)
        return r
    }
}

public extension Decimal {
    var sar: String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return (f.string(from: self as NSDecimalNumber) ?? "\(self)") + " ر.س"
    }

    init?(arabic s: String) {
        let clean = s.applyingArabicDigits().replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, let d = Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        self = d
    }
}
