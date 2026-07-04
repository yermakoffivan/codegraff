import Foundation
import Security

// Keychain-backed storage for the codegraff API key - same device-login
// credential the CLI keeps in ~/.simple-harness-codegraff.json.
enum KeychainStore {
    private static let service = "com.codegraff.graff"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ account: String, _ value: String) -> OSStatus {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        return SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// Gateway REST client: the same device-code login flow as `graff login`
// (POST /v1/device/start -> user approves on codegraff.com -> poll yields the
// cg_sk_ key), plus the account's sandboxes (list / spin down) - the iOS
// counterpart of `graff sandboxes`.
struct DeviceStart: Decodable {
    let device_code: String
    let user_code: String
    let verification_uri: String?
    let verification_uri_complete: String?
    let interval: Int?
    let expires_in: Int?
}

struct Sandbox: Decodable, Identifiable {
    let id: String
    let state: String
    let cpu: Int
    let memory: Int
    let disk: Int
    let labels: [String: String]?
    let createdAt: String?
    var label: String { labels?["purpose"] ?? labels?["app"] ?? "" }
}

// POST /v1/sandboxes returns a thinner object than the list rows, so decode
// just what the broker needs.
struct SandboxCreated: Decodable {
    let id: String
    let state: String?
}

struct ExecResult: Decodable {
    let exitCode: Int?
    let result: String?
    let execId: String?
}

struct PortPreview: Decodable {
    let url: String
    let token: String?
}

enum GatewayError: LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        switch self { case .http(let c, let m): return "gateway HTTP \(c): \(m)" }
    }
}

enum Gateway {
    static let base = "https://gateway.codegraff.com"
    private static let keyAccount = "codegraff-api-key"

    // In-memory copy of the key: a Keychain persistence failure (ad-hoc sim
    // builds without entitlements hit errSecMissingEntitlement) must not kill
    // the just-signed-in session — worst case you sign in again next launch.
    private static var memoryKey: String?

    // GRAFF_GATEWAY_KEY env override mirrors GRAFF_SERVE_BASE/TOKEN: it lets
    // the autotest harness inject a signed-in state without a device approval.
    static var apiKey: String? {
        ProcessInfo.processInfo.environment["GRAFF_GATEWAY_KEY"] ?? memoryKey ?? KeychainStore.get(keyAccount)
    }
    static func signIn(key: String) {
        memoryKey = key
        let status = KeychainStore.set(keyAccount, key)
        if status != errSecSuccess { NSLog("Graff: keychain store failed (%d)", status) }
    }
    static func signOut() {
        memoryKey = nil
        KeychainStore.delete(keyAccount)
    }

    private static func request(_ path: String, method: String, json: [String: Any]? = nil, authed: Bool) -> URLRequest {
        var r = URLRequest(url: URL(string: base + path)!)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Graff-iOS/0.1", forHTTPHeaderField: "User-Agent") // CF WAF rejects empty UA
        if authed, let key = apiKey { r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        if let json { r.httpBody = try? JSONSerialization.data(withJSONObject: json) }
        return r
    }

    private static func check(_ data: Data, _ resp: URLResponse) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(code) else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }.flatMap { $0["message"] as? String }
            throw GatewayError.http(code, msg ?? String(decoding: data.prefix(120), as: UTF8.self))
        }
    }

    static func deviceStart() async throws -> DeviceStart {
        let (data, resp) = try await URLSession.shared.data(for:
            request("/v1/device/start", method: "POST", json: ["device_label": "graff-ios"], authed: false))
        try check(data, resp)
        return try JSONDecoder().decode(DeviceStart.self, from: data)
    }

    // One poll step: "ok" delivers the key; anything unparseable counts as pending.
    static func devicePoll(_ deviceCode: String) async throws -> (status: String, key: String?) {
        let (data, resp) = try await URLSession.shared.data(for:
            request("/v1/device/poll", method: "POST", json: ["device_code": deviceCode], authed: false))
        try check(data, resp)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (obj["status"] as? String ?? "pending", obj["api_key"] as? String)
    }

    static func sandboxes() async throws -> [Sandbox] {
        let (data, resp) = try await URLSession.shared.data(for:
            request("/v1/sandboxes", method: "GET", authed: true))
        try check(data, resp)
        return try JSONDecoder().decode([Sandbox].self, from: data)
    }

    static func stopSandbox(_ id: String) async throws -> String {
        let (data, resp) = try await URLSession.shared.data(for:
            request("/v1/sandboxes/\(id)/stop", method: "POST", json: [:], authed: true))
        try check(data, resp)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return obj["state"] as? String ?? "stopped"
    }

    // The cube broker's REST legs — the same calls `graff cube new` makes.
    static func createSandbox(purpose: String, autoStopMinutes: Int = 30) async throws -> SandboxCreated {
        let (data, resp) = try await URLSession.shared.data(for:
            request("/v1/sandboxes", method: "POST",
                    json: ["autoStopMinutes": autoStopMinutes, "labels": ["purpose": purpose]], authed: true))
        try check(data, resp)
        return try JSONDecoder().decode(SandboxCreated.self, from: data)
    }

    static func sandboxInfo(_ id: String) async throws -> Sandbox {
        let (data, resp) = try await URLSession.shared.data(for:
            request("/v1/sandboxes/\(id)", method: "GET", authed: true))
        try check(data, resp)
        return try JSONDecoder().decode(Sandbox.self, from: data)
    }

    static func exec(_ id: String, command: String, timeoutSeconds: Int, async asynch: Bool = false) async throws -> ExecResult {
        var body: [String: Any] = ["command": command, "timeoutSeconds": timeoutSeconds]
        if asynch { body["async"] = true }
        var req = request("/v1/sandboxes/\(id)/exec", method: "POST", json: body, authed: true)
        req.timeoutInterval = Double(timeoutSeconds) + 15 // outlive the sandbox-side timeout
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(data, resp)
        return try JSONDecoder().decode(ExecResult.self, from: data)
    }

    static func preview(_ id: String, port: Int) async throws -> PortPreview {
        let (data, resp) = try await URLSession.shared.data(for:
            request("/v1/sandboxes/\(id)/ports/\(port)/preview", method: "GET", authed: true))
        try check(data, resp)
        return try JSONDecoder().decode(PortPreview.self, from: data)
    }
}
