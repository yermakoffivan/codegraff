import Foundation
import Security

// Everything a serve client needs to stream turns into a sandbox cube, plus
// the sandbox id for spin-down. Persisted in the Keychain so a relaunch can
// reattach to a still-running cube instead of paying spin-up again.
struct CubeConnection: Codable, Equatable {
    let sandboxID: String
    let base: String        // Daytona preview URL fronting the serve port
    let serveToken: String
    let previewToken: String?

    private static let account = "cube-connection"
    static func stored() -> CubeConnection? {
        guard let raw = KeychainStore.get(account), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CubeConnection.self, from: data)
    }
    func store() {
        if let data = try? JSONEncoder().encode(self), let s = String(data: data, encoding: .utf8) {
            KeychainStore.set(Self.account, s)
        }
    }
    static func clearStored() { KeychainStore.delete(account) }
}

// Client-side mirror of `graff cube new` (the CLI got the capability first):
// create a gateway sandbox -> install graff -> start `graff serve` behind a
// fresh token -> mint the Daytona preview URL. A still-running stored cube is
// reused rather than duplicated, exactly like the CLI.
enum CubeBroker {
    static let port = 8787

    struct StepError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func launch(purpose: String, onStep: @escaping @MainActor (String) -> Void) async throws -> CubeConnection {
        if let old = CubeConnection.stored() {
            await onStep("Checking the running cube…")
            if let info = try? await Gateway.sandboxInfo(old.sandboxID), info.state == "started" {
                return old
            }
            CubeConnection.clearStored()
        }

        await onStep("Creating sandbox…")
        let created = try await Gateway.createSandbox(purpose: purpose)
        var state = created.state ?? ""
        var waits = 0
        while state != "started" && waits < 60 {
            try await Task.sleep(for: .seconds(2))
            state = (try? await Gateway.sandboxInfo(created.id).state) ?? state
            waits += 1
        }
        guard state == "started" else { throw StepError(message: "sandbox never reached started (\(state))") }

        await onStep("Installing graff…")
        let inst = try await Gateway.exec(created.id,
            command: "curl -fsSL https://raw.githubusercontent.com/justrach/codegraff/main/install.sh | bash",
            timeoutSeconds: 120)
        guard inst.exitCode == 0 else {
            throw StepError(message: "graff install failed: \(String((inst.result ?? "").suffix(200)))")
        }

        await onStep("Starting graff serve…")
        guard let key = Gateway.apiKey else { throw StepError(message: "not signed in") }
        let token = freshToken()
        _ = try await Gateway.exec(created.id,
            command: "CODEGRAFF_API_KEY=\(key) exec $HOME/bin/graff serve --host 0.0.0.0 --port \(port) --token \(token)",
            timeoutSeconds: 60, async: true)
        var up = false
        for _ in 0..<20 {
            if let probe = try? await Gateway.exec(created.id,
                command: "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:\(port)/", timeoutSeconds: 15) {
                let code = (probe.result ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n'"))
                if !code.isEmpty && code != "000" { up = true; break }
            }
            try await Task.sleep(for: .seconds(1))
        }
        guard up else { throw StepError(message: "serve never came up in the sandbox") }

        await onStep("Minting preview URL…")
        let pv = try await Gateway.preview(created.id, port: port)
        let base = pv.url.hasSuffix("/") ? String(pv.url.dropLast()) : pv.url
        let conn = CubeConnection(sandboxID: created.id, base: base, serveToken: token, previewToken: pv.token)
        conn.store()
        return conn
    }

    private static func freshToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
