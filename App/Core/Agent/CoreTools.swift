import Foundation

/// Registers the Foundation-only tools (no UIKit / EventKit / network).
public enum CoreTools {
    public static func register(into r: ToolRegistry, knowledge: KnowledgeBase = .shared, notes: NotesStore = .shared,
                                memory: MemoryStore = .shared, now: @escaping () -> Date = Date.init) {
        r.register(ClosureTool(ToolSpec(
            name: "memory_save", title: "حفظ في الذاكرة", icon: "brain.head.profile",
            description: "Remember a lasting fact about the user (name, preferences, city, job…) for future chats.",
            parameters: [ToolParameter("fact", "string", "one short fact, e.g. 'يسكن في جدة'")])) { a in
            guard let f = a.string("fact"), !f.isEmpty else { throw ToolError("fact مطلوب") }
            return memory.add(f) ? "تم الحفظ في الذاكرة: \(f)" : "المعلومة محفوظة مسبقاً."
        })

        r.register(ClosureTool(ToolSpec(
            name: "memory_search", title: "البحث في الذاكرة", icon: "brain",
            description: "Search what you remember about the user.",
            parameters: [ToolParameter("query", "string", "what to look for", required: false)])) { a in
            let res = memory.search(a.string("query") ?? "")
            return res.isEmpty ? "لا توجد ذكريات محفوظة." : res.map { "- \($0.text)" }.joined(separator: "\n")
        })

        r.register(ClosureTool(ToolSpec(
            name: "calculator", title: "الحاسبة", icon: "plus.forwardslash.minus",
            description: "Evaluate an exact arithmetic expression. Supports + - * / ^ % ( ) sqrt().",
            parameters: [ToolParameter("expression", "string", "e.g. (1250*12)*0.15")])) { a in
            guard let e = a.string("expression"), !e.isEmpty else { throw ToolError("expression مطلوب") }
            return "\(e) = \(Calculator.format(try Calculator.evaluate(e)))"
        })

        r.register(ClosureTool(ToolSpec(
            name: "current_datetime", title: "التاريخ والوقت", icon: "clock",
            description: "Get the current local date/time in Saudi Arabia (Hijri and Gregorian).")) { _ in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = Hijri.riyadh
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return "\(Hijri.describe(now())) — الساعة \(f.string(from: now())) (ISO: \(f.string(from: now())) +03:00)"
        })

        r.register(ClosureTool(ToolSpec(
            name: "hijri_date", title: "التاريخ الهجري", icon: "calendar",
            description: "Convert between Hijri (Umm al-Qura) and Gregorian dates. Leave date empty for today.",
            parameters: [ToolParameter("date", "string", "YYYY-MM-DD", required: false),
                         ToolParameter("from", "string", "'hijri' or 'gregorian'", required: false)])) { a in
            guard let s = a.string("date"), !s.isEmpty, let p = Hijri.parse(s) else { return Hijri.describe(now()) }
            let fromHijri = (a.string("from") ?? "").lowercased().contains("hijri") || p.year < 1600
            let d = fromHijri ? Hijri.date(hijri: p) : Hijri.date(gregorian: p)
            guard let date = d else { throw ToolError("تاريخ غير صالح") }
            return Hijri.describe(date)
        })

        r.register(ClosureTool(ToolSpec(
            name: "prayer_times", title: "مواقيت الصلاة", icon: "moon.stars",
            description: "Prayer times (Umm al-Qura) for a Saudi city on a date.",
            parameters: [ToolParameter("city", "string", "Saudi city in Arabic, e.g. الرياض"),
                         ToolParameter("date", "string", "Gregorian YYYY-MM-DD, default today", required: false)])) { a in
            let name = a.string("city") ?? "الرياض"
            guard let c = PrayerTimes.city(named: name) else {
                throw ToolError("المدينة غير معروفة. المتاح: \(PrayerTimes.cities.map(\.name).joined(separator: "، "))")
            }
            let date = a.string("date").flatMap(Hijri.parse).flatMap { Hijri.date(gregorian: $0) } ?? now()
            let t = PrayerTimes.compute(date: date, latitude: c.latitude, longitude: c.longitude)
            var out = "مواقيت الصلاة في \(c.name) — \(Hijri.describe(date)):\n\(t.describe())"
            if let n = t.next(after: now()), Calendar.current.isDate(date, inSameDayAs: now()) {
                out += "\nالصلاة القادمة: \(n.name)"
            }
            return out
        })

        r.register(ClosureTool(ToolSpec(
            name: "qibla", title: "اتجاه القبلة", icon: "location.north.line",
            description: "Qibla bearing and distance to Makkah from a Saudi city.",
            parameters: [ToolParameter("city", "string", "city name in Arabic")])) { a in
            guard let c = PrayerTimes.city(named: a.string("city") ?? "") else { throw ToolError("المدينة غير معروفة") }
            let b = Qibla.bearing(latitude: c.latitude, longitude: c.longitude)
            let d = Qibla.distanceKm(latitude: c.latitude, longitude: c.longitude)
            return String(format: "اتجاه القبلة من %@: %.1f° من الشمال الجغرافي، والمسافة إلى الكعبة %.0f كم.", c.name, b, d)
        })

        r.register(ClosureTool(ToolSpec(
            name: "zakat", title: "حاسبة الزكاة", icon: "banknote",
            description: "Compute zakat (2.5%) in SAR. Nisab = 85g gold.",
            parameters: [ToolParameter("cash", "number", "cash & bank balances SAR", required: false),
                         ToolParameter("gold_grams", "number", "24k gold grams", required: false),
                         ToolParameter("gold_price", "number", "SAR per gram of 24k gold"),
                         ToolParameter("trade_goods", "number", "trade goods value SAR", required: false),
                         ToolParameter("stocks", "number", "zakatable stocks SAR", required: false),
                         ToolParameter("receivables", "number", "expected receivables SAR", required: false),
                         ToolParameter("debts", "number", "debts due now SAR", required: false)])) { a in
            var i = Zakat.Input()
            i.cash = a.decimal("cash") ?? 0
            i.goldGrams24k = a.decimal("gold_grams") ?? 0
            i.goldPricePerGram = a.decimal("gold_price") ?? 0
            i.tradeGoods = a.decimal("trade_goods") ?? 0
            i.stocks = a.decimal("stocks") ?? 0
            i.receivables = a.decimal("receivables") ?? 0
            i.debtsDue = a.decimal("debts") ?? 0
            let r = Zakat.compute(i)
            return """
            إجمالي الأموال الزكوية: \(r.totalWealth.sar)
            النصاب (85 جرام ذهب): \(i.goldPricePerGram > 0 ? r.nisab.sar : "غير محدد — أعطني سعر جرام الذهب")
            \(r.isDue ? "بلغ النصاب. الزكاة الواجبة (2.5%): \(r.zakat.sar)" : "لم يبلغ النصاب، لا زكاة.")
            """
        })

        r.register(ClosureTool(ToolSpec(
            name: "vat", title: "ضريبة القيمة المضافة", icon: "percent",
            description: "Saudi VAT 15%. mode 'add' adds VAT to a net price; 'extract' extracts it from a VAT-inclusive price.",
            parameters: [ToolParameter("amount", "number", "amount in SAR"),
                         ToolParameter("mode", "string", "'add' or 'extract'")])) { a in
            guard let amt = a.decimal("amount") else { throw ToolError("amount مطلوب") }
            let extract = (a.string("mode") ?? "add").lowercased().contains("ex")
            let b = extract ? VAT.extract(from: amt) : VAT.add(to: amt)
            return "قبل الضريبة: \(b.net.sar)\nالضريبة 15%: \(b.vat.sar)\nالإجمالي شامل الضريبة: \(b.gross.sar)"
        })

        r.register(ClosureTool(ToolSpec(
            name: "end_of_service", title: "مكافأة نهاية الخدمة", icon: "briefcase",
            description: "Saudi Labor Law end-of-service award.",
            parameters: [ToolParameter("monthly_wage", "number", "last total monthly wage SAR"),
                         ToolParameter("years", "number", "years of service, fractions allowed"),
                         ToolParameter("reason", "string", "'termination' or 'resignation'")])) { a in
            guard let w = a.decimal("monthly_wage"), let y = a.decimal("years") else { throw ToolError("monthly_wage و years مطلوبة") }
            let resign = (a.string("reason") ?? "").lowercased().contains("resign") || (a.string("reason") ?? "").contains("استقال")
            let v = EndOfService.compute(monthlyWage: w, years: y, reason: resign ? .resignation : .terminatedByEmployer)
            return "مكافأة نهاية الخدمة التقديرية (\(resign ? "استقالة" : "إنهاء من صاحب العمل")): \(v.sar)\nالمرجع: المادتان 84 و85 من نظام العمل."
        })

        r.register(ClosureTool(ToolSpec(
            name: "knowledge_search", title: "البحث في المعرفة", icon: "books.vertical",
            description: "Search the user's imported documents. Returns relevant passages with document titles.",
            parameters: [ToolParameter("query", "string", "search query")])) { a in
            let q = a.string("query") ?? ""
            let hits = knowledge.search(q, limit: 4)
            if hits.isEmpty {
                return knowledge.documents.isEmpty ? "قاعدة المعرفة فارغة. أضف مستندات من تبويب المزيد ← المعرفة." : "لا توجد نتائج مطابقة."
            }
            return hits.enumerated().map { "[\($0.offset + 1)] [\($0.element.documentTitle)]\n\($0.element.chunk)" }
                .joined(separator: "\n---\n")
        })

        r.register(ClosureTool(ToolSpec(
            name: "read_document", title: "قراءة مستند", icon: "doc.text",
            description: "Read the beginning of an imported document by title, or list documents if title is empty.",
            parameters: [ToolParameter("title", "string", "document title", required: false)])) { a in
            let t = a.string("title") ?? ""
            if t.isEmpty || knowledge.document(titled: t) == nil {
                let list = knowledge.documents.map { "- \($0.title)" }.joined(separator: "\n")
                return list.isEmpty ? "لا توجد مستندات." : "المستندات المتاحة:\n\(list)"
            }
            let d = knowledge.document(titled: t)!
            return "[\(d.title)]\n" + d.chunks.prefix(3).joined(separator: "\n")
        })

        r.register(ClosureTool(ToolSpec(
            name: "notes_add", title: "حفظ ملاحظة", icon: "note.text.badge.plus",
            description: "Save a note or code snippet locally.",
            parameters: [ToolParameter("title", "string", "short title"), ToolParameter("body", "string", "content")])) { a in
            let n = Note(title: a.string("title") ?? "ملاحظة", body: a.string("body") ?? "")
            notes.add(n)
            return "تم حفظ الملاحظة \"\(n.title)\"."
        })

        r.register(ClosureTool(ToolSpec(
            name: "notes_search", title: "البحث في الملاحظات", icon: "note.text",
            description: "Search saved notes. Empty query lists recent notes.",
            parameters: [ToolParameter("query", "string", "search text", required: false)])) { a in
            let res = notes.search(a.string("query") ?? "")
            return res.isEmpty ? "لا توجد ملاحظات." : res.map { "• \($0.title): \($0.body.prefix(300))" }.joined(separator: "\n")
        })
    }
}
