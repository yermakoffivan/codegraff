import SwiftUI

struct ChatView: View {
    @Binding var session: AgentSession
    var autoSend: String? = nil

    @State private var draft: String = ""
    // Cube sessions carry their own transport; everything else uses the
    // env/loopback default (local serve on the host Mac).
    private var client: GraffServeClient {
        session.cube.map { GraffServeClient(cube: $0) } ?? GraffServeClient()
    }
    @State private var serveSessionID: String?
    @State private var streaming = false
    @State private var didAutoSend = false

    var body: some View {
        VStack(spacing: 0) {
            if !session.todos.isEmpty {
                TaskProgressCard(session: session)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(session.messages) { msg in
                            MessageBubble(message: msg).id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: session.messages.last?.text) {
                    if let last = session.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if session.planPending {
                PlanDecisionBar(
                    onImplement: {
                        session.planPending = false
                        session.status = .working
                    },
                    onKeepPlanning: { session.planPending = false }
                )
                .padding(.horizontal)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Composer(draft: $draft, streaming: streaming, onSend: send)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy, value: session.planPending)
        .task {
            if let p = autoSend, !didAutoSend {
                didAutoSend = true
                draft = p
                send()
            }
        }
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !streaming else { return }
        draft = ""
        session.messages.append(ChatMessage(role: .user, text: t))
        streaming = true
        session.status = .working
        Task { await runTurn(t) }
    }

    @MainActor
    private func runTurn(_ text: String) async {
        defer { streaming = false }
        do {
            if serveSessionID == nil {
                serveSessionID = try await client.createSession(model: session.model, yolo: session.cube != nil)
            }
            session.messages.append(ChatMessage(role: .assistant, text: ""))
            let idx = session.messages.count - 1
            for try await ev in client.streamTurn(sessionID: serveSessionID!, text: text) {
                switch ev {
                case .reasoning(let r):
                    session.messages[idx].reasoning = (session.messages[idx].reasoning ?? "") + r
                case .text(let d):
                    session.messages[idx].text += d
                case .turn(let final, _, _):
                    session.messages[idx].text = final
                case .error(let m):
                    session.messages[idx].text = "Error: " + m
                case .toolCall(let name):
                    session.messages[idx].reasoning = ((session.messages[idx].reasoning ?? "") + "\n⚙️ \(name)")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                case .other:
                    break
                }
            }
            session.status = .idle
        } catch {
            session.messages.append(ChatMessage(role: .assistant,
                text: "Transport error: \(error.localizedDescription)"))
            session.status = .idle
        }
    }
}

struct TaskProgressCard: View {
    let session: AgentSession
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Task progress", systemImage: "checklist")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(session.progress.done)/\(session.progress.total)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(session.todos) { todo in
                HStack(spacing: 8) {
                    Image(systemName: todo.status.symbol)
                        .foregroundStyle(todo.status.tint)
                        .symbolEffect(.pulse, isActive: todo.status == .inProgress)
                    Text(todo.title)
                        .font(.callout)
                        .strikethrough(todo.status == .completed, color: .secondary)
                        .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .glassPanel(22)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    private var isBlank: Bool { message.text.isEmpty && (message.reasoning?.isEmpty ?? true) }
    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                if let r = message.reasoning, !r.isEmpty {
                    Label(r, systemImage: "brain")
                        .font(.caption).italic()
                        .foregroundStyle(.secondary)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                } else if message.role == .assistant && isBlank {
                    TypingIndicator()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(message.role == .user ? Color.blue.opacity(0.9) : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

// Three pulsing dots shown in the assistant bubble while a turn is in flight
// but no reasoning/text has streamed yet (e.g. during a tool call) - so an
// in-progress turn never looks like an empty, stuck bubble.
struct TypingIndicator: View {
    @State private var animating = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .frame(width: 7, height: 7)
                    .foregroundStyle(.secondary)
                    .scaleEffect(animating ? 1.0 : 0.5)
                    .opacity(animating ? 1.0 : 0.4)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.2), value: animating)
            }
        }
        .padding(.vertical, 2)
        .onAppear { animating = true }
    }
}

struct PlanDecisionBar: View {
    let onImplement: () -> Void
    let onKeepPlanning: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Label("Plan ready for review", systemImage: "list.clipboard")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Button("Keep planning", action: onKeepPlanning)
                    .buttonStyle(.glass)
                Button("Implement plan", action: onImplement)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(16)
        .glassPanel(22)
    }
}

struct Composer: View {
    @Binding var draft: String
    var streaming: Bool = false
    let onSend: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            TextField("Type a message", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .glassCapsule()
                .disabled(streaming)
            Button(action: onSend) {
                Image(systemName: streaming ? "ellipsis" : "arrow.up")
                    .font(.headline.weight(.bold))
            }
            .buttonStyle(.glassProminent)
            .disabled(streaming || draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
