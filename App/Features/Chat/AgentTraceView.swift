import SwiftUI

struct AgentTraceView: View {
    let steps: [AgentStep]
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                StepRow(step: s, isLast: i == steps.count - 1 && !live)
            }
            if live {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("يعمل…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 4).padding(.top, 6)
            }
        }
    }

    struct StepRow: View {
        let step: AgentStep
        let isLast: Bool
        @State private var expanded = false

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 0) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(color)
                        .frame(width: 24, height: 24)
                        .background(color.opacity(0.12), in: Circle())
                    if !isLast {
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1.5)
                            .frame(maxHeight: .infinity)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title).font(.subheadline.weight(.medium))
                    if !step.detail.isEmpty {
                        Text(step.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 3)
                            .textSelection(.enabled)
                    }
                }
                .padding(.bottom, 10)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        }

        var icon: String {
            switch step.kind {
            case .thought: return "brain"
            case .toolCall: return "hammer.fill"
            case .toolResult: return "checkmark"
            case .denied: return "hand.raised.fill"
            case .error: return "exclamationmark.triangle.fill"
            case .final: return "flag.checkered"
            }
        }

        var color: Color {
            switch step.kind {
            case .thought: return .purple
            case .toolCall: return .blue
            case .toolResult: return .green
            case .denied: return .orange
            case .error: return .red
            case .final: return .accentColor
            }
        }
    }
}
