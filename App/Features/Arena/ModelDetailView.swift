import SwiftUI

/// Per-model tuning plus real speed and quality measurements.
struct ModelDetailView: View {
    @EnvironmentObject var state: AppState
    let ref: String
    let displayName: String

    @State private var tuning = ModelTuning()
    @State private var speed: SpeedReport?
    @State private var report: EvalReport?
    @State private var busy = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        Form {
            Section("النموذج") {
                LabeledContent("الاسم", value: displayName)
                LabeledContent("المسار", value: ref == "local" ? "على الجهاز" : "سحابي")
            }

            Section("إعدادات هذا النموذج") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("الحرارة")
                        Spacer()
                        Text(String(format: "%.2f", tuning.temperature ?? state.settings.generation.temperature))
                            .foregroundStyle(.secondary).monospaced()
                    }
                    Slider(value: Binding(
                        get: { tuning.temperature ?? state.settings.generation.temperature },
                        set: { tuning.temperature = $0 }), in: 0...1.5)
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("top-p")
                        Spacer()
                        Text(String(format: "%.2f", tuning.topP ?? state.settings.generation.topP))
                            .foregroundStyle(.secondary).monospaced()
                    }
                    Slider(value: Binding(
                        get: { tuning.topP ?? state.settings.generation.topP },
                        set: { tuning.topP = $0 }), in: 0.1...1.0)
                }
                Stepper("أقصى رموز: \(tuning.maxTokens ?? state.settings.generation.maxTokens)",
                        value: Binding(
                            get: { tuning.maxTokens ?? state.settings.generation.maxTokens },
                            set: { tuning.maxTokens = $0 }), in: 128...8192, step: 128)
                Button {
                    ModelTuningStore.shared.set(tuning, for: ref)
                    saved = true
                } label: {
                    Label(saved ? "تم الحفظ" : "حفظ الإعدادات", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                }
                Button(role: .destructive) {
                    tuning = ModelTuning()
                    ModelTuningStore.shared.remove(ref)
                    saved = false
                } label: { Label("إرجاع الافتراضي", systemImage: "arrow.counterclockwise") }
            }

            Section("القياس") {
                Button {
                    Task { await measureSpeed() }
                } label: {
                    Label(busy ? "جاري القياس…" : "قياس السرعة (64 رمزاً)", systemImage: "speedometer")
                }
                .disabled(busy || !state.isReady(ref))

                if let s = speed {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.1f رمز/ث", s.tokensPerSecond)).font(.title3.bold())
                        Text("\(s.tokens) رمز في \(String(format: "%.2f", s.seconds)) ث · سياق \(s.promptTokens)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("تقييم الجودة") {
                Button {
                    Task { await runEval() }
                } label: {
                    Label(busy ? "جاري التقييم…" : "تشغيل 6 اختبارات حتمية", systemImage: "checklist")
                }
                .disabled(busy || !state.isReady(ref))

                if let r = report {
                    HStack {
                        Text("\(r.passed)/\(r.results.count)").font(.title3.bold())
                        Spacer()
                        Text(String(format: "%.0f%%", r.score * 100)).foregroundStyle(.secondary)
                    }
                    ForEach(r.results) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(item.name, systemImage: item.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(item.passed ? .green : .red)
                                .font(.footnote)
                            if !item.passed {
                                Text(item.output).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle(displayName)
        .onAppear { tuning = ModelTuningStore.shared.tuning(for: ref) }
    }

    func measureSpeed() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            speed = try await SpeedBenchmark.run(backend: state.backend(for: ref),
                                                 modelName: displayName,
                                                 base: tuning.applied(to: state.settings.generation))
        } catch { self.error = error.localizedDescription }
    }

    func runEval() async {
        busy = true; error = nil
        defer { busy = false }
        report = await QualityEval.evaluate(backend: state.backend(for: ref),
                                            modelName: displayName,
                                            base: tuning.applied(to: state.settings.generation))
    }
}
