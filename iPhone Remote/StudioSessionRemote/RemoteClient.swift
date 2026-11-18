import Foundation

/// Talks to Studio Session's iPhone Remote server (plain HTTP + JSON, port 47820).
struct RemoteClient {
    enum ClientError: LocalizedError {
        case unreachable
        case unpaired(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .unreachable: return "Can't reach the Mac."
            case .unpaired(let text): return text
            case .server(let text): return text
            }
        }
    }

    struct ActionResult: Decodable {
        var result: String
        var message: String?
        var warnings: [String]?
    }

    struct PairResult: Decodable {
        var token: String
        var deviceID: String
        var macName: String
        var port: Int
        var lan: [String]
        var tailscale: [String]
    }

    struct Hello: Decodable {
        var app: String
        var macName: String
        var version: String
        var pairing: String
    }

    static let defaultPort = 47820

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func url(host: String, port: Int, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        return components.url
    }

    static func request(host: String, port: Int, method: String, path: String, token: String?,
                        body: [String: Any]? = nil, timeout: TimeInterval) async throws -> Data {
        guard let url = url(host: host, port: port, path: path) else { throw ClientError.unreachable }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 { return data }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        if status == 401 { throw ClientError.unpaired(message ?? "This iPhone isn't paired any more.") }
        throw ClientError.server(message ?? "The Mac answered with error \(status).")
    }

    static func hello(host: String, port: Int) async throws -> Hello {
        let data = try await request(host: host, port: port, method: "GET", path: "/v1/hello", token: nil, timeout: 4)
        return try decoder.decode(Hello.self, from: data)
    }

    static func pair(host: String, port: Int, code: String, deviceName: String, deviceKey: String) async throws -> PairResult {
        let data = try await request(host: host, port: port, method: "POST", path: "/v1/pair", token: nil,
                                     body: ["code": code, "deviceName": deviceName, "deviceKey": deviceKey], timeout: 8)
        return try decoder.decode(PairResult.self, from: data)
    }

    static func status(host: String, port: Int, token: String, timeout: TimeInterval) async throws -> RemoteStatus {
        let data = try await request(host: host, port: port, method: "GET", path: "/v1/status", token: token, timeout: timeout)
        do {
            return try decoder.decode(RemoteStatus.self, from: data)
        } catch {
            throw ClientError.server("The Mac sent a status this app can't read. Update Studio Session and this app to matching versions.")
        }
    }

    static func action(host: String, port: Int, token: String, path: String, body: [String: Any]? = nil) async throws -> ActionResult {
        // A backup request waits for the Mac's drive check, which can take several seconds.
        let data = try await request(host: host, port: port, method: "POST", path: path, token: token, body: body ?? [:], timeout: 45)
        return try decoder.decode(ActionResult.self, from: data)
    }
}
