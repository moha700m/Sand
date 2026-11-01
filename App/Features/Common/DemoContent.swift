import Foundation

/// Sample content used only when launched with `-demo YES` (CI screenshots).
@MainActor
enum DemoContent {
    static func install(into state: AppState) {
        let now = Date()
        var chat = Conversation(title: "رسالة تهنئة بالعيد", personaID: Persona.general.id)
        chat.messages = [
            ChatMessage(role: .user, content: "اكتب لي رسالة تهنئة قصيرة بالعيد لزملائي في العمل"),
            ChatMessage(role: .assistant, content: """
            **عيدكم مبارك** 🌙

            أسأل الله أن يعيده علينا وعليكم بالخير واليُمن والبركات، وأن يجعل أيامكم كلها أفراحاً ونجاحاً.
            سعدت بالعمل معكم هذا العام، وكل عام وأنتم بخير.

            — زميلكم
            """, tokensPerSecond: 23.4, tokenCount: 61),
            ChatMessage(role: .user, content: "حوّلها للهجة نجدية"),
            ChatMessage(role: .assistant, content: "عساكم من عوّاده 🌙\nكل عام وأنتم بخير يا الربع، الله يعيده علينا وعليكم بالصحة والسعادة، وتراني مستانس إني أشتغل معكم. عيدكم مبارك!",
                        tokensPerSecond: 24.1, tokenCount: 42),
        ]
        chat.updatedAt = now

        var agentChat = Conversation(title: "زكاة المدخرات", agentID: "finance")
        agentChat.messages = [
            ChatMessage(role: .user, content: "عندي 120,000 ريال في البنك، وسعر جرام الذهب 410 ريال. كم زكاتي؟"),
            ChatMessage(role: .assistant, content: sampleAnswer, agentSteps: sampleSteps),
        ]
        agentChat.updatedAt = now.addingTimeInterval(-3600)

        state.conversations = [chat, agentChat]
        if state.providers.isEmpty {
            state.providers = [ProviderConfig(id: "demo-claude", kind: .anthropic),
                               ProviderConfig(id: "demo-openrouter", kind: .openRouter, model: "openai/gpt-5-mini")]
        }
        if state.memory.all.isEmpty {
            state.memory.add("اسمه محمد ويسكن في الرياض")
            state.memory.add("يفضّل الإجابات المختصرة بالأرقام")
            state.memory.add("مطوّر iOS ويحب Swift")
        }
        if state.knowledge.documents.isEmpty {
            state.knowledge.add(title: "عقد إيجار الشقة", text: "مدة العقد سنة ميلادية تبدأ من 1 يناير 2027. قيمة الإيجار السنوي 36,000 ريال تدفع على دفعتين. التأمين 2,000 ريال يسترد عند نهاية العقد.")
        }
    }

    static let sampleSteps: [AgentStep] = [
        AgentStep(kind: .thought, title: "خطة", detail: "أحتاج حساب الزكاة باستخدام أداة الزكاة مع سعر الذهب لمعرفة النصاب."),
        AgentStep(kind: .toolCall, title: "حاسبة الزكاة", detail: "{\"cash\":\"120000\",\"gold_price\":\"410\"}", toolName: "zakat"),
        AgentStep(kind: .toolResult, title: "نتيجة حاسبة الزكاة",
                  detail: "إجمالي الأموال الزكوية: 120,000.00 ر.س\nالنصاب (85 جرام ذهب): 34,850.00 ر.س\nبلغ النصاب. الزكاة الواجبة (2.5%): 3,000.00 ر.س", toolName: "zakat"),
        AgentStep(kind: .final, title: "الإجابة", detail: sampleAnswer),
    ]

    static let sampleAnswer = """
    مالك بلغ النصاب ✅

    - **النصاب:** 85 جرام × 410 = **34,850 ر.س**
    - **الوعاء الزكوي:** 120,000 ر.س
    - **الزكاة الواجبة (2.5%):** **3,000 ر.س**

    تجب إذا حال عليها الحول الهجري. المرجع الرسمي: هيئة الزكاة والضريبة والجمارك.
    """

    static func fillAgentRun(goal: inout String, steps: inout [AgentStep], answer: inout String) {
        goal = "عندي 120,000 ريال في البنك، وسعر جرام الذهب 410 ريال. كم زكاتي؟"
        steps = sampleSteps
        answer = sampleAnswer
    }
}
