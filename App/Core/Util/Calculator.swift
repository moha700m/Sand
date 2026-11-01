import Foundation

/// Exact decimal expression evaluator: + - * / ^ % parentheses, unary minus, Arabic digits,
/// and functions sqrt(), abs(), round().
public enum Calculator {
    public enum CalcError: LocalizedError, Equatable {
        case syntax(String), divisionByZero
        public var errorDescription: String? {
            switch self {
            case .syntax(let s): return "تعبير غير صالح: \(s)"
            case .divisionByZero: return "قسمة على صفر"
            }
        }
    }

    public static func evaluate(_ expression: String) throws -> Decimal {
        var p = Parser(Array(expression.applyingArabicDigits().replacingOccurrences(of: " ", with: "")))
        let v = try p.parseExpression()
        guard p.i == p.chars.count else { throw CalcError.syntax(String(p.chars[p.i...])) }
        return v
    }

    public static func format(_ d: Decimal) -> String {
        let r = VAT.round(d, scale: 10)
        return NSDecimalNumber(decimal: r).stringValue
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        init(_ c: [Character]) { chars = c }

        mutating func parseExpression() throws -> Decimal {
            var v = try parseTerm()
            while i < chars.count, chars[i] == "+" || chars[i] == "-" {
                let op = chars[i]; i += 1
                let r = try parseTerm()
                v = op == "+" ? v + r : v - r
            }
            return v
        }

        mutating func parseTerm() throws -> Decimal {
            var v = try parsePower()
            while i < chars.count, "*/%".contains(chars[i]) {
                let op = chars[i]; i += 1
                if op == "%" && (i >= chars.count || "+-*/)".contains(chars[i])) {
                    v = v / 100 // postfix percent
                    continue
                }
                let r = try parsePower()
                switch op {
                case "*": v *= r
                case "/": guard r != 0 else { throw CalcError.divisionByZero }; v /= r
                default:
                    guard r != 0 else { throw CalcError.divisionByZero }
                    let q = (NSDecimalNumber(decimal: v / r).doubleValue).rounded(.towardZero)
                    v = v - Decimal(q) * r
                }
            }
            return v
        }

        mutating func parsePower() throws -> Decimal {
            let base = try parseUnary()
            if i < chars.count, chars[i] == "^" {
                i += 1
                let exp = try parsePower()
                let e = NSDecimalNumber(decimal: exp).doubleValue
                if e == e.rounded(), abs(e) <= 64 {
                    var r: Decimal = 1
                    for _ in 0..<Int(abs(e)) { r *= base }
                    return e < 0 ? 1 / r : r
                }
                return Decimal(pow(NSDecimalNumber(decimal: base).doubleValue, e))
            }
            return base
        }

        mutating func parseUnary() throws -> Decimal {
            if i < chars.count, chars[i] == "-" { i += 1; return -(try parseUnary()) }
            if i < chars.count, chars[i] == "+" { i += 1; return try parseUnary() }
            return try parsePrimary()
        }

        mutating func parsePrimary() throws -> Decimal {
            guard i < chars.count else { throw CalcError.syntax("نهاية غير متوقعة") }
            if chars[i] == "(" {
                i += 1
                let v = try parseExpression()
                guard i < chars.count, chars[i] == ")" else { throw CalcError.syntax("قوس ناقص") }
                i += 1
                return v
            }
            if chars[i].isLetter {
                var name = ""
                while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
                guard i < chars.count, chars[i] == "(" else { throw CalcError.syntax(name) }
                let arg = try parsePrimary()
                let dv = NSDecimalNumber(decimal: arg).doubleValue
                switch name.lowercased() {
                case "sqrt": return Decimal(dv.squareRoot())
                case "abs": return arg < 0 ? -arg : arg
                case "round": return VAT.round(arg, scale: 0)
                default: throw CalcError.syntax(name)
                }
            }
            var s = ""
            while i < chars.count, chars[i].isNumber || chars[i] == "." { s.append(chars[i]); i += 1 }
            guard !s.isEmpty, let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else {
                throw CalcError.syntax(String(chars[i]))
            }
            return d
        }
    }
}
