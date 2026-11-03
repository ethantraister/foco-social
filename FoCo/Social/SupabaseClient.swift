import Foundation
import Security

enum SocialConfig {
    /// Set SUPABASE_URL and SUPABASE_ANON_KEY in Info.plist to point at a real Supabase project.
    /// Without them the app talks to the local test server (backend/local/dev_server.py).
    /// Debug builds launched with `-useLocalServer YES` (the UI tests) ignore Info.plist and use the test server.
    /// Debug builds with FOCO_DEMO_SERVER set in Info.plist use the test server on your Mac (run it with --lan);
    /// clear FOCO_DEMO_SERVER to go back to the live project. Release builds always use the live project.
    private static var localServer: String? {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "useLocalServer") { return "http://localhost:54321" }
        let demo = Bundle.main.object(forInfoDictionaryKey: "FOCO_DEMO_SERVER") as? String ?? ""
        return demo.isEmpty ? nil : demo
        #else
        return nil
        #endif
    }

    static var url: URL {
        let raw = localServer ?? Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        return URL(string: raw.isEmpty ? "http://localhost:54321" : raw)!
    }

    static var anonKey: String {
        let raw = localServer != nil ? "" : Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
        return raw.isEmpty ? localAnonKey : raw
    }

    static var isLocalDemo: Bool {
        guard let host = url.host else { return true }
        return host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") || host.hasPrefix("192.168.") || host.hasPrefix("10.")
    }

    private static let localAnonKey = "eyJhbGciOiAiSFMyNTYiLCAidHlwIjogIkpXVCJ9.eyJyb2xlIjogImFub24iLCAiaXNzIjogImZvY28tbG9jYWwiLCAiZXhwIjogNDEwMjQ0NDgwMH0.-uUu0q5JaomITeMzrjYg7J6Xn5oAMIjDwF7ei6U5B8E"
}

struct AuthSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double
    var userId: UUID
    var email: String
}

enum APIError: LocalizedError {
    case server(String, status: Int = 0)
    /// No connection, or the server didn't answer. Never signs you out.
    case offline
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .server(let message, _): message
        case .offline: "Can't connect right now. Check your connection and try again."
        case .notSignedIn: "Please sign in again."
        }
    }

    var status: Int {
        if case .server(_, let status) = self { return status }
        return 0
    }
}

@MainActor
final class SupabaseClient {
    let baseURL = SocialConfig.url
    let anonKey = SocialConfig.anonKey
    private(set) var session: AuthSession? {
        didSet { Keychain.save(session.flatMap { try? JSONEncoder().encode($0) }, for: "session") }
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }()

    // ISO8601DateFormatter is thread-safe, and making one per date was the slowest part of decoding a feed.
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated static func parseDate(_ s: String) -> Date? {
        fractionalFormatter.date(from: s) ?? plainFormatter.date(from: s)
    }

    static func isoString(_ date: Date) -> String { plainFormatter.string(from: date) }
    /// With milliseconds, for "messages newer than this one" (several can arrive in the same second).
    static func preciseString(_ date: Date) -> String { fractionalFormatter.string(from: date) }

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-resetForUITests") { Keychain.save(nil, for: "session") }
        #endif
        session = Keychain.load("session").flatMap { try? JSONDecoder().decode(AuthSession.self, from: $0) }
    }

    // MARK: Auth

    func sendCode(to email: String) async throws {
        _ = try await send("POST", "/auth/v1/otp", json: ["email": email, "create_user": true], authed: false)
    }

    func verify(email: String, code: String) async throws {
        let data = try await send("POST", "/auth/v1/verify", json: ["type": "email", "email": email, "token": code], authed: false)
        try adopt(data)
    }

    /// Only for the App Review account, which can't receive the emailed code. Other accounts have no password.
    func signIn(email: String, password: String) async throws {
        let data = try await send("POST", "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "password")],
                                  json: ["email": email, "password": password], authed: false)
        try adopt(data)
    }

    func signOut() {
        if let token = session?.accessToken {
            var req = URLRequest(url: baseURL.appendingPathComponent("/auth/v1/logout"))
            req.httpMethod = "POST"
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: req).resume()
        }
        session = nil
    }

    private struct TokenResponse: Decodable {
        struct User: Decodable { let id: UUID; let email: String? }
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
        let user: User
    }

    private func adopt(_ data: Data) throws {
        let t = try Self.decoder.decode(TokenResponse.self, from: data)
        session = AuthSession(accessToken: t.accessToken, refreshToken: t.refreshToken,
                              expiresAt: Date.now.timeIntervalSince1970 + t.expiresIn,
                              userId: t.user.id, email: t.user.email ?? session?.email ?? "")
    }

    private func validToken() async throws -> String {
        guard let s = session else { throw APIError.notSignedIn }
        if s.expiresAt - Date.now.timeIntervalSince1970 > 60 { return s.accessToken }
        try await refresh()
        guard let token = session?.accessToken else { throw APIError.notSignedIn }
        return token
    }

    private var refreshTask: Task<Void, Error>?

    private func refresh() async throws {
        if let refreshTask { return try await refreshTask.value }
        guard let s = session else { throw APIError.notSignedIn }
        let task = Task {
            do {
                let data = try await send("POST", "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                          json: ["refresh_token": s.refreshToken], authed: false)
                try adopt(data)
            } catch APIError.offline {
                // Opening the app without a connection keeps you signed in; the token refreshes once you're back online.
                throw APIError.offline
            } catch let error as APIError where error.status >= 500 {
                throw APIError.offline
            } catch {
                session = nil
                throw APIError.notSignedIn
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    // MARK: Requests

    @discardableResult
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil, body: Data? = nil,
              contentType: String = "application/json", prefer: String? = nil, authed: Bool = true, retried: Bool = false) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if authed { req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization") }
        if let json { req.httpBody = try JSONSerialization.data(withJSONObject: json) }
        if let body { req.httpBody = body }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && authed && !retried {
            try await refresh()
            return try await send(method, path, query: query, json: json, body: body, contentType: contentType, prefer: prefer, authed: authed, retried: true)
        }
        guard (200..<300).contains(status) else { throw APIError.server(Self.message(from: data, status: status), status: status) }
        return data
    }

    private static func message(from data: Data, status: Int) -> String {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let raw = (obj?["message"] ?? obj?["msg"] ?? obj?["error_description"]) as? String ?? "Something went wrong (\(status))."
        if raw.contains("Invalid login credentials") { return "That password didn't work." }
        if raw.contains("you can only request this after") || raw.contains("over_email_send_rate_limit") { return "A code was just sent. Wait a minute before asking for another." }
        if raw.contains("row-level security") { return "You don't have permission to do that." }
        if raw.contains("duplicate key") || raw.contains("friendships_one_per_pair") { return "That's already done." }
        if raw.contains("expired or is invalid") { return "That code didn't work. Check it or send a new one." }
        return raw
    }

    func rpc<T: Decodable>(_ name: String, _ args: [String: Any] = [:]) async throws -> T {
        let data = try await send("POST", "/rest/v1/rpc/\(name)", json: args)
        return try Self.decoder.decode(T.self, from: data)
    }

    func rpcVoid(_ name: String, _ args: [String: Any] = [:]) async throws {
        try await send("POST", "/rest/v1/rpc/\(name)", json: args)
    }

    func select<T: Decodable>(_ table: String, _ query: [String: String]) async throws -> [T] {
        let data = try await send("GET", "/rest/v1/\(table)", query: query.map { URLQueryItem(name: $0.key, value: $0.value) })
        return try Self.decoder.decode([T].self, from: data)
    }

    /// `upsert` updates a row that's already there; `ignoreDuplicates` leaves it alone (for tables you can't update).
    @discardableResult
    func insert(_ table: String, _ values: [String: Any], upsert: Bool = false, ignoreDuplicates: Bool = false,
                returning: Bool = false) async throws -> Data {
        var prefer = [returning ? "return=representation" : "return=minimal"]
        if upsert { prefer.append("resolution=merge-duplicates") }
        if ignoreDuplicates { prefer.append("resolution=ignore-duplicates") }
        return try await send("POST", "/rest/v1/\(table)", json: values, prefer: prefer.joined(separator: ","))
    }

    func update(_ table: String, where filters: [String: String], _ values: [String: Any]) async throws {
        try await send("PATCH", "/rest/v1/\(table)", query: filters.map { URLQueryItem(name: $0.key, value: $0.value) }, json: values, prefer: "return=minimal")
    }

    func delete(_ table: String, where filters: [String: String]) async throws {
        try await send("DELETE", "/rest/v1/\(table)", query: filters.map { URLQueryItem(name: $0.key, value: $0.value) }, prefer: "return=minimal")
    }

    func upload(jpeg: Data, to path: String) async throws {
        try await send("POST", "/storage/v1/object/meal-photos/\(path)", body: jpeg, contentType: "image/jpeg")
    }

    func publicURL(_ path: String) -> URL {
        baseURL.appendingPathComponent("/storage/v1/object/public/meal-photos/\(path)")
    }

    /// Paths of every photo in your own folder (meal photos and profile photos).
    func myPhotoPaths() async throws -> [String] {
        guard let id = session?.userId.uuidString.lowercased() else { throw APIError.notSignedIn }
        struct Object: Decodable { let name: String; let id: String? }
        let data = try await send("POST", "/storage/v1/object/list/meal-photos", json: ["prefix": id, "limit": 1000])
        return try Self.decoder.decode([Object].self, from: data).filter { $0.id != nil }.map { "\(id)/\($0.name)" }
    }

    func deletePhotos(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await send("DELETE", "/storage/v1/object/meal-photos", json: ["prefixes": paths])
    }
}

enum Keychain {
    private static let service = "FoCoSocial"

    static func save(_ data: Data?, for key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "fallback.\(key)")
        guard let data else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) == errSecMissingEntitlement {
            // Unsigned simulator builds have no keychain; real installs always use it.
            UserDefaults.standard.set(data, forKey: "fallback.\(key)")
        }
    }

    static func load(_ key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess { return result as? Data }
        return UserDefaults.standard.data(forKey: "fallback.\(key)")
    }
}
