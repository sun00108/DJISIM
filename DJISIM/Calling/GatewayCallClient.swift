#if os(iOS)
import Foundation

enum GatewayCallClientError: LocalizedError {
    case invalidConfiguration
    case invalidResponse
    case server(status: Int, detail: String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "网关地址或 Bearer Token 无效。"
        case .invalidResponse: "网关返回了无法识别的响应。"
        case let .server(status, detail): "网关通话 API 错误（HTTP \(status)）：\(detail)"
        case let .protocolError(detail): "网关通话协议错误：\(detail)"
        }
    }
}

struct GatewayCallClient: Sendable {
    let baseURL: URL
    let token: String
    let session: URLSession

    init(
        serverAddress: String = AppConfiguration.serverAddress,
        token: String = AppConfiguration.token,
        session: URLSession = .shared
    ) throws {
        let value = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              var components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased()),
              components.host != nil else {
            throw GatewayCallClientError.invalidConfiguration
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = components.url else {
            throw GatewayCallClientError.invalidConfiguration
        }
        baseURL = url
        self.token = token
        self.session = session
    }

    func currentCall() async throws -> GatewayCallRecord? {
        let data = try await request(path: "/api/v1/calls/current")
        return try decode(Optional<GatewayCallRecord>.self, from: data)
    }

    func call(id: String) async throws -> GatewayCallRecord {
        let data = try await request(path: "/api/v1/calls/\(id)")
        return try decode(GatewayCallRecord.self, from: data)
    }

    func calls(limit: Int = 50) async throws -> [GatewayCallRecord] {
        let data = try await request(path: "/api/v1/calls?limit=\(limit)")
        return try decode(GatewayCallList.self, from: data).items
    }

    func answer(callID: String, installationID: UUID) async throws -> GatewayCallRecord {
        try await deviceAction(path: "/api/v1/calls/\(callID)/answer", installationID: installationID)
    }

    func hangup(callID: String, installationID: UUID) async throws -> GatewayCallRecord? {
        _ = try await request(
            path: "/api/v1/calls/\(callID)/hangup",
            method: "POST",
            body: try deviceBody(installationID)
        )
        // 当前网关返回 {call_id, result}；调用方只需要确认挂断请求已被接受。
        return nil
    }

    func start(number: String, installationID: UUID) async throws -> GatewayCallRecord {
        let body = try JSONSerialization.data(withJSONObject: [
            "frontend": "app",
            "number": number,
            "installation_id": installationID.uuidString.lowercased(),
        ])
        let data = try await request(path: "/api/v1/calls/start", method: "POST", body: body)
        return try decode(GatewayCallRecord.self, from: data)
    }

    func audioTicket(callID: String, installationID: UUID) async throws -> GatewayAudioTicket {
        let data = try await request(
            path: "/api/v1/calls/\(callID)/audio-ticket",
            method: "POST",
            body: try deviceBody(installationID)
        )
        return try decode(GatewayAudioTicket.self, from: data)
    }

    func sendDTMF(
        callID: String,
        digit: Character,
        installationID: UUID
    ) async throws -> GatewayDTMFAcknowledgement {
        let body = try JSONSerialization.data(withJSONObject: [
            "installation_id": installationID.uuidString.lowercased(),
            "digit": String(digit),
        ])
        let request = try makeRequest(
            path: "/api/v1/calls/\(callID)/dtmf",
            method: "POST",
            body: body
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayCallClientError.invalidResponse
        }
        guard http.statusCode == 200 else {
            try validate(response: response, data: data)
            throw GatewayCallClientError.protocolError(
                "DTMF 成功响应应为 HTTP 200，实际为 HTTP \(http.statusCode)"
            )
        }
        let acknowledgement = try decode(GatewayDTMFAcknowledgement.self, from: data)
        guard acknowledgement.accepted, acknowledgement.callID == callID else {
            throw GatewayCallClientError.protocolError(
                "DTMF 响应与当前通话不匹配或未被接受"
            )
        }
        return acknowledgement
    }

    func webSocketURL(callID: String) throws -> URL {
        guard var components = URLComponents(
            url: URL(string: "/api/v1/calls/\(callID)/audio", relativeTo: baseURL)!,
            resolvingAgainstBaseURL: true
        ) else { throw GatewayCallClientError.invalidConfiguration }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { throw GatewayCallClientError.invalidConfiguration }
        return url
    }

    func streamCallEvents(
        onConnected: @escaping @Sendable () async -> Void = {},
        handler: @escaping @Sendable (GatewayCallRecord) async -> Void
    ) async throws {
        var request = try makeRequest(path: "/api/v1/events", method: "GET", body: nil)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60 * 60
        let (bytes, response) = try await session.bytes(for: request)
        try validate(response: response, data: nil)
        await onConnected()

        var eventName: String?
        var dataLines: [String] = []
        var lineBytes: [UInt8] = []
        var receivedFirstByte = false
        for try await byte in bytes {
            try Task.checkCancellation()
            if !receivedFirstByte {
                receivedFirstByte = true
                await MainActor.run {
                    AppLog.shared.append("📡 通话 SSE 已收到响应体数据")
                }
            }
            guard byte == 0x0A else {
                lineBytes.append(byte)
                // 防止异常服务端持续发送不换行的数据导致无限占用内存。
                if lineBytes.count > 1_048_576 {
                    throw GatewayCallClientError.protocolError("SSE 单行数据超过 1 MiB")
                }
                continue
            }
            if lineBytes.last == 0x0D { lineBytes.removeLast() }
            let line = String(decoding: lineBytes, as: UTF8.self)
            lineBytes.removeAll(keepingCapacity: true)

            if line.isEmpty {
                if !dataLines.isEmpty {
                    let data = Data(dataLines.joined(separator: "\n").utf8)
                    let rawEventName = eventName ?? "(未指定)"
                    await MainActor.run {
                        AppLog.shared.append("📡 SSE 原始事件：\(rawEventName)")
                    }
                    do {
                        let envelope = try JSONDecoder().decode(GatewayEventEnvelope.self, from: data)
                        if envelope.type == "call.state",
                           eventName == nil || eventName == "call.state" {
                            await handler(envelope.payload)
                        }
                    } catch {
                        if eventName == "call.state" {
                            await MainActor.run {
                                AppLog.shared.append(
                                    "⚠️ SSE call.state 解码失败：\(error.localizedDescription)"
                                )
                            }
                        }
                    }
                }
                eventName = nil
                dataLines.removeAll(keepingCapacity: true)
            } else if line.hasPrefix("event:") {
                eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        try Task.checkCancellation()
        throw GatewayCallClientError.protocolError("SSE 连接已关闭")
    }

    private func deviceAction(path: String, installationID: UUID) async throws -> GatewayCallRecord {
        let data = try await request(path: path, method: "POST", body: try deviceBody(installationID))
        return try decode(GatewayCallRecord.self, from: data)
    }

    private func deviceBody(_ installationID: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "installation_id": installationID.uuidString.lowercased(),
        ])
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let request = try makeRequest(path: path, method: method, body: body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    private func makeRequest(path: String, method: String, body: Data?) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw GatewayCallClientError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GatewayCallClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = data.flatMap { try? JSONDecoder().decode(CallAPIError.self, from: $0).detail }
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GatewayCallClientError.server(status: http.statusCode, detail: detail)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw GatewayCallClientError.protocolError(error.localizedDescription) }
    }
}

private struct CallAPIError: Decodable {
    let detail: String
}
#endif
