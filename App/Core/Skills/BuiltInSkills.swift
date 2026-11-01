import Foundation

/// Shipped skills. Each body is real operating guidance for the agent, not a placeholder.
public enum BuiltInSkills {
    public static let all: [SkillPackage] = [
        SkillPackage(
            id: "ios-swiftui", name: "تطوير iOS بـ SwiftUI",
            summary: "بناء شاشات SwiftUI وتنظيم المشاريع ومراجعة الكود قبل التسليم.", version: "1.0.0",
            category: .ios,
            tools: ["workspace_write", "workspace_read", "workspace_search", "run_javascript"],
            inputs: ["goal"],
            body: """
            # تطوير iOS
            1. اسأل نفسك: هل المطلوب شاشة أم منطق؟ إن كان منطقاً فنفّذه في ملف منفصل قابل للاختبار.
            2. اكتب الملفات في مساحة العمل بهيكل واضح: `Sources/Features/<Name>/<Name>View.swift`.
            3. استخدم SwiftUI القياسي فقط: `VStack`, `List`, `NavigationStack`, `@StateObject`. لا تخترع API غير موجود.
            4. لكل شاشة: حالة تحميل، حالة فراغ، حالة خطأ.
            5. بعد الكتابة، استعرض الملفات بـ `workspace_list` وتأكد أن الأسماء متسقة مع الاستيراد.
            6. لا تدّعي أن الكود تم تجميعه. قل "جاهز للمراجعة" إن لم تُنفَّذ عملية بناء حقيقية.
            """,
            builtIn: true),
        SkillPackage(
            id: "code-review", name: "مراجعة كود صارمة",
            summary: "مراجعة منهجية تبحث عن الأخطاء الحقيقية أولاً ثم التحسينات.", version: "1.0.0",
            category: .programming,
            tools: ["workspace_read", "workspace_search", "workspace_write"],
            inputs: ["path"],
            body: """
            # مراجعة كود
            اقرأ الملف بـ `workspace_read`. راجع بهذا الترتيب واذكر رقم السطر:
            1. أخطاء تمنع التشغيل: أنواع خاطئة، متغيرات غير معرّفة، استدعاءات API غير متوافقة.
            2. أخطاء منطقية: شروط مقلوبة، حالات حدّية، تعامل مع nil، تزامن.
            3. أمان: مسارات ملفات، حقن، أسرار مكتوبة في الكود، شبكة بلا تحقق.
            4. أداء: حلقات متداخلة، إعادة حساب داخل `body`، عمليات على الـmain thread.
            5. أسلوب: تسمية، تكرار، طول الدالة.
            اكتب النتيجة كقائمة مرقمة: الخطورة، الموقع، الإصلاح المقترح. لا تجامل.
            """,
            builtIn: true),
        SkillPackage(
            id: "deep-research", name: "بحث موثّق",
            summary: "بحث متعدد المصادر مع تحقق وتوثيق المراجع.", version: "1.0.0",
            category: .research,
            tools: ["web_search", "fetch_url", "notes_add"],
            inputs: ["question"],
            body: """
            # منهج البحث
            1. صِغ 3 استعلامات مختلفة الزاوية (تعريف، أرقام، نقد).
            2. اقرأ 3–5 مصادر كاملة بـ `fetch_url`؛ لا تعتمد على المقتطفات.
            3. سجّل لكل معلومة: المصدر وتاريخه. تجاهل ما لا تاريخ له إذا كان رقماً متغيراً.
            4. عند التعارض، اذكر التعارض ولا تختار عشوائياً.
            5. اكتب: ملخص تنفيذي (5 أسطر)، ثم تفاصيل بعناوين، ثم قائمة مراجع مرقمة بروابط.
            """,
            builtIn: true),
        SkillPackage(
            id: "arabic-writing", name: "كتابة عربية احترافية",
            summary: "تحرير النصوص العربية: وضوح، إيجاز، اتساق المصطلح.", version: "1.0.0",
            category: .writing,
            tools: ["workspace_read", "workspace_write"],
            inputs: ["text"],
            body: """
            # تحرير عربي
            - جملة واحدة = فكرة واحدة. اقتل الحشو: "في الحقيقة"، "كما نعلم جميعاً".
            - لا تخلط الفصحى والعامية في نفس النص إلا في الحوار.
            - وحّد المصطلح: اختر مصطلحاً واحداً للمفهوم الواحد وكرّره.
            - الأرقام: استخدم الأرقام الغربية (1، 2، 3) في النصوص التقنية، والعربية في النصوص الأدبية إن طُلب.
            - أعد كتابة النص كاملاً، ثم اذكر في سطرين أهم ما غيّرته ولماذا.
            """,
            builtIn: true),
        SkillPackage(
            id: "document-analysis", name: "تحليل مستندات",
            summary: "استخراج وتلخيص ومقارنة مستندات المستخدم مع الاستشهاد بالمصدر.", version: "1.0.0",
            category: .documents,
            tools: ["knowledge_search", "read_document", "workspace_write"],
            inputs: ["document", "question"],
            body: """
            # تحليل مستند
            1. ابحث في قاعدة المعرفة أولاً بـ `knowledge_search` بثلاث صيغ للسؤال.
            2. إن لم تجد، اسأل المستخدم عن اسم المستند الصحيح بدل التخمين.
            3. اقتبس الجملة الحرفية بين «» عند الاستشهاد، واذكر اسم المستند.
            4. للعقود: استخرج الأطراف، المدة، المقابل المالي، الالتزامات، شروط الإنهاء، الغرامات.
            5. نبّه صراحةً إن كان المستند ممسوحاً ضوئياً ولم يُستخرج نصه.
            """,
            builtIn: true),
        SkillPackage(
            id: "data-analysis", name: "تحليل بيانات",
            summary: "حساب وتحليل دقيق عبر JavaScript مع جدول نتائج.", version: "1.0.0",
            category: .data,
            tools: ["run_javascript", "calculator", "workspace_read", "workspace_write"],
            inputs: ["csv", "question"],
            body: """
            # تحليل بيانات
            1. لا تحسب ذهنياً. اكتب كوداً وشغّله بـ `run_javascript` واطبع النتائج بـ console.log.
            2. ابدأ بفحص البيانات: عدد الصفوف، القيم الفارغة، أنواع الأعمدة.
            3. احسب: المتوسط، الوسيط، الانحراف المعياري، أعلى/أدنى 5 قيم.
            4. اذكر أي افتراض (مثل حذف الصفوف الفارغة) صراحةً.
            5. النتيجة في جدول Markdown + 3 استنتاجات قابلة للتنفيذ.
            """,
            builtIn: true),
        SkillPackage(
            id: "saudi-business", name: "أعمال سعودية",
            summary: "زكاة، ضريبة 15%، نهاية خدمة، تقويم هجري ومواقيت الصلاة.", version: "1.0.0",
            category: .business,
            tools: ["zakat", "vat", "end_of_service", "hijri_date", "prayer_times", "calculator"],
            inputs: ["amount"],
            body: """
            # أعمال سعودية
            - استخدم الأدوات دائماً: `zakat`, `vat`, `end_of_service`. لا تحسب يدوياً.
            - اذكر النصاب (85 جرام ذهب) وسعر الجرام المستخدم.
            - ضريبة القيمة المضافة 15%، ووضّح إن كان المبلغ شامل الضريبة أم لا.
            - مكافأة نهاية الخدمة: فرّق بين الاستقالة والإنهاء، وطبّق مادتي 84 و85.
            - في كل إجابة مالية: «المرجع الرسمي هيئة الزكاة والضريبة والجمارك / وزارة الموارد البشرية».
            """,
            builtIn: true),
        SkillPackage(
            id: "prompt-engineering", name: "هندسة أوامر",
            summary: "كتابة أوامر نظام واضحة وقابلة للاختبار للنماذج المحلية.", version: "1.0.0",
            category: .aiDev,
            tools: ["workspace_write", "notes_add"],
            inputs: ["task"],
            body: """
            # هندسة أوامر
            - ابدأ بالدور والهدف في سطرين، لا بصفحة مقدمات.
            - حدّد المخرجات: الصيغة، الطول، اللغة، ما يُمنع.
            - للنماذج الصغيرة (1–4B): جملة واحدة لكل تعليم، وأمثلة قليلة، ومخرجات مقيّدة.
            - ضع الأوامر في ملف `.md` داخل مساحة العمل ليمكن إعادة استخدامها.
            - اختبر الأمر على حالة واحدة صعبة واذكر النتيجة.
            """,
            builtIn: true),
        SkillPackage(
            id: "automation", name: "أتمتة مهام",
            summary: "تحويل الطلب المتكرر إلى أداة قابلة للاستدعاء.", version: "1.0.0",
            category: .automation,
            tools: ["workspace_write", "run_javascript", "http_request"],
            inputs: ["task"],
            body: """
            # أتمتة
            1. اكتب المهمة كخطوات مرقمة، وحدّد المدخلات والمخرجات.
            2. إن كانت حسابية أو نصية: أنشئ أداة JavaScript بمخطط مدخلات واضح.
            3. إن كانت شبكية: أداة HTTP مع إذن صريح، وتحقّق من الاستجابة قبل استخدامها.
            4. اختبر الأداة بمدخل حقيقي واحد واذكر الناتج.
            5. لا تنشئ أداة تكتب خارج مساحة العمل دون تأكيد المستخدم.
            """,
            builtIn: true),
    ]
}
