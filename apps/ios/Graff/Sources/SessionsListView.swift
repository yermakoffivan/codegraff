import SwiftUI

struct SessionsListView: View {
    @State private var sessions = sampleSessions
    @State private var showAccount = false
    @State private var showNewSession = false

    var body: some View {
        NavigationStack {
            List {
                ForEach($sessions) { $session in
                    NavigationLink {
                        ChatView(session: $session)
                    } label: {
                        SessionRow(session: session)
                    }
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAccount = true } label: { Image(systemName: "person.crop.circle") }
                        .buttonStyle(.glass)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewSession = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.glass)
                }
            }
            .sheet(isPresented: $showAccount) { AccountView() }
            .sheet(isPresented: $showNewSession) {
                NewSessionView { newSession in sessions.insert(newSession, at: 0) }
            }
        }
    }
}

struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.title).font(.headline).lineLimit(1)
                Spacer()
                StatusChip(status: session.status)
            }
            HStack(spacing: 10) {
                Label(session.model, systemImage: "cpu")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("\(session.progress.done)/\(session.progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(session.lastActivity).font(.caption2).foregroundStyle(.tertiary)
            }
            ProgressView(value: Double(session.progress.done),
                         total: Double(max(session.progress.total, 1)))
                .tint(session.status.tint)
        }
        .padding(.vertical, 4)
    }
}

struct StatusChip: View {
    let status: SessionStatus
    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .font(.caption2.weight(.medium))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassCapsule()
    }
}
