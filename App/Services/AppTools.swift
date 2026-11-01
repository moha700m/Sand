import EventKit
import Foundation

/// Tools that need iOS frameworks or app state (EventKit, Lens, network).
enum AppTools {
    static let eventStore = EKEventStore()

    @MainActor
    static func register(into r: ToolRegistry, state: AppState) {
        r.register(ClosureTool(ToolSpec(
            name: "create_reminder", title: "إضافة تذكير", icon: "bell.badge",
            description: "Create a reminder in the iOS Reminders app. Requires user approval.",
            parameters: [ToolParameter("title", "string", "reminder text"),
                         ToolParameter("due", "string", "local due date-time 'YYYY-MM-DD HH:mm' (Riyadh time)", required: false)],
            requiresConfirmation: true)) { a in
            guard let title = a.string("title"), !title.isEmpty else { throw ToolError("title مطلوب") }
            guard try await eventStore.requestFullAccessToReminders() else { throw ToolError("لم يُسمح بالوصول إلى التذكيرات") }
            let rem = EKReminder(eventStore: eventStore)
            rem.title = title
            rem.calendar = eventStore.defaultCalendarForNewReminders()
            if let s = a.string("due"), let d = parseLocal(s) {
                rem.dueDateComponents = Calendar(identifier: .gregorian).dateComponents(in: Hijri.riyadh, from: d)
                rem.addAlarm(EKAlarm(absoluteDate: d))
            }
            try eventStore.save(rem, commit: true)
            return "تمت إضافة التذكير \"\(title)\"\(a.string("due").map { " في \($0)" } ?? "")."
        })

        r.register(ClosureTool(ToolSpec(
            name: "create_event", title: "إضافة موعد", icon: "calendar.badge.plus",
            description: "Add an event to the iOS Calendar. Requires user approval.",
            parameters: [ToolParameter("title", "string", "event title"),
                         ToolParameter("start", "string", "'YYYY-MM-DD HH:mm' Riyadh time"),
                         ToolParameter("minutes", "number", "duration in minutes, default 60", required: false)],
            requiresConfirmation: true)) { a in
            guard let title = a.string("title"), let s = a.string("start"), let start = parseLocal(s) else {
                throw ToolError("title و start مطلوبة بصيغة YYYY-MM-DD HH:mm")
            }
            guard try await eventStore.requestWriteOnlyAccessToEvents() else { throw ToolError("لم يُسمح بالوصول إلى التقويم") }
            let e = EKEvent(eventStore: eventStore)
            e.title = title
            e.startDate = start
            e.endDate = start.addingTimeInterval(Double(Int(a.string("minutes") ?? "60") ?? 60) * 60)
            e.calendar = eventStore.defaultCalendarForNewEvents
            try eventStore.save(e, span: .thisEvent)
            return "تمت إضافة الموعد \"\(title)\" بتاريخ \(s)."
        })

        r.register(ClosureTool(ToolSpec(
            name: "image_text", title: "نص الصورة", icon: "text.viewfinder",
            description: "Return the text recognised (OCR) from the most recent image captured in the Lens tab.")) { [weak state] _ in
            let text = await MainActor.run { state?.lastImageText }
            guard let text, !text.isEmpty else { return "لا توجد صورة حديثة. التقط صورة من تبويب العدسة أولاً." }
            return text
        })

        r.register(ClosureTool(ToolSpec(
            name: "fetch_url", title: "قراءة صفحة ويب", icon: "doc.richtext",
            description: "Download a web page and return its readable text (title + content). Use after web_search to read sources.",
            parameters: [ToolParameter("url", "string", "full https URL")],
            usesNetwork: true)) { a in
            guard let s = a.string("url"), let url = URL(string: s), url.scheme?.hasPrefix("http") == true else {
                throw ToolError("رابط غير صالح")
            }
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let raw = String(decoding: data, as: UTF8.self)
            if type.contains("json") || type.contains("text/plain") { return String(raw.prefix(10000)) }
            let page = HTMLText.extract(raw, limit: 10000)
            return "العنوان: \(page.title)\nالرابط: \(s)\n\n\(page.text)"
        })

        r.register(ClosureTool(ToolSpec(
            name: "run_javascript", title: "مفسّر الكود", icon: "curlybraces",
            description: "Execute JavaScript (ES2023, no DOM/network) in a sandbox and return console.log output. Use for precise math, data analysis, sorting, dates, string processing.",
            parameters: [ToolParameter("code", "string", "JavaScript source; print results with console.log")])) { a in
            guard let code = a.string("code"), !code.isEmpty else { throw ToolError("code مطلوب") }
            return try await JSRunner.run(code)
        })

        r.register(ClosureTool(ToolSpec(
            name: "web_search", title: "بحث الويب", icon: "globe",
            description: "Search the web (DuckDuckGo) and return top results with snippets. Only when local knowledge is insufficient.",
            parameters: [ToolParameter("query", "string", "search query")],
            usesNetwork: true)) { a in
            try await WebSearch.search(a.string("query") ?? "")
        })

        r.register(ClosureTool(ToolSpec(
            name: "http_request", title: "طلب API", icon: "network",
            description: "Call an external HTTP API. Use only for endpoints the user asked for. Requires approval.",
            parameters: [ToolParameter("url", "string", "https URL"),
                         ToolParameter("method", "string", "GET, POST, PUT, DELETE", required: false),
                         ToolParameter("body", "string", "JSON body for POST/PUT", required: false)],
            requiresConfirmation: true, usesNetwork: true)) { a in
            guard let s = a.string("url"), let url = URL(string: s) else { throw ToolError("رابط غير صالح") }
            let scheme = url.scheme?.lowercased() ?? ""
            let local = (url.host ?? "") == "localhost" || (url.host ?? "").hasPrefix("192.168.") || (url.host ?? "").hasPrefix("10.")
            guard scheme == "https" || (scheme == "http" && local) else { throw ToolError("يُسمح بـ https فقط") }
            var req = URLRequest(url: url)
            req.httpMethod = (a.string("method") ?? "GET").uppercased()
            req.timeoutInterval = 30
            if let body = a.string("body"), !body.isEmpty, req.httpMethod != "GET" {
                req.httpBody = Data(body.utf8)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(decoding: data.prefix(12000), as: UTF8.self)
            return "HTTP \(status)\n\(text)"
        })
    }

    static func parseLocal(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Hijri.riyadh
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s.applyingArabicDigits().trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }
}

enum WebSearch {
    static func search(_ query: String) async throws -> String {
        guard !query.isEmpty else { throw ToolError("query مطلوب") }
        var c = URLComponents(string: "https://html.duckduckgo.com/html/")!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "kl", value: "xa-ar")]
        var req = URLRequest(url: c.url!)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(decoding: data, as: UTF8.self)
        let results = parse(html).prefix(5)
        if results.isEmpty { return "لا توجد نتائج." }
        return results.enumerated().map { "[\($0.offset + 1)] \($0.element.title)\n\($0.element.url)\n\($0.element.snippet)" }
            .joined(separator: "\n\n")
    }

    struct Result { var title: String; var url: String; var snippet: String }

    static func parse(_ html: String) -> [Result] {
        var out: [Result] = []
        let blocks = html.components(separatedBy: "class=\"result__a\"").dropFirst()
        for b in blocks {
            let href = b.slice(from: "href=\"", to: "\"") ?? ""
            let title = (b.slice(from: ">", to: "</a>") ?? "").strippingTags
            let snippet = (b.slice(from: "class=\"result__snippet\"", to: "</a>") ?? "").dropFirstTag.strippingTags
            var url = href
            if let r = href.range(of: "uddg="), let decoded = String(href[r.upperBound...]).components(separatedBy: "&").first?.removingPercentEncoding {
                url = decoded
            }
            if !title.isEmpty { out.append(Result(title: title, url: url, snippet: snippet)) }
        }
        return out
    }
}

extension String {
    func slice(from a: String, to b: String) -> String? {
        guard let r1 = range(of: a), let r2 = range(of: b, range: r1.upperBound..<endIndex) else { return nil }
        return String(self[r1.upperBound..<r2.lowerBound])
    }

    var strippingTags: String {
        var s = replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var dropFirstTag: String {
        guard let i = firstIndex(of: ">") else { return self }
        return String(self[index(after: i)...])
    }
}
