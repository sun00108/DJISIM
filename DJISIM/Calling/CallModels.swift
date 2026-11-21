#if os(iOS)
import Foundation

enum GatewayCallState: String, Codable, Sendable {
    case idle
    case waitingClient = "waiting_client"
    case waitingTelegram = "waiting_telegram"
    case waitingCellular = "waiting_cellular"
    case ringingCellular = "ringing_cellular"
    case active
    case hangingUp = "hanging_up"
    case failed
    case ended

    var isTerminal: Bool { self == .ended || self == .failed }
}

enum GatewayCallDirection: String, Codable, Sendable {
    case inboundCellular = "inbound_cellular"
    case outboundCellular = "outbound_cellular"
}

struct GatewayCallRecord: Codable, Identifiable, Sendable {
    let id: String
    let direction: GatewayCallDirection
    let state: GatewayCallState
    let cellularNumber: String?
    let frontend: String
    let startedAt: String?
    let connectedAt: String?
    let endedAt: String?
    let lastError: String?
    let ownerInstallationID: String?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id, direction, state, frontend
        case cellularNumber = "cellular_number"
        case startedAt = "started_at"
        case connectedAt = "connected_at"
        case endedAt = "ended_at"
        case lastError = "last_error"
        case ownerInstallationID = "owner_installation_id"
        case expiresAt = "expires_at"
    }

    var callUUID: UUID? { UUID(uuidString: id) }
}

struct GatewayCallList: Decodable, Sendable {
    let items: [GatewayCallRecord]
}

struct GatewayAudioTicket: Decodable, Sendable {
    let ticket: String
    let expiresIn: Double
    let subprotocolName: String

    enum CodingKeys: String, CodingKey {
        case ticket
        case expiresIn = "expires_in"
        case subprotocolName = "subprotocol"
    }
}

struct GatewayDTMFAcknowledgement: Decodable, Sendable {
    let callID: String
    let accepted: Bool

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case accepted
    }
}

struct GatewayEventEnvelope: Decodable, Sendable {
    let type: String
    let payload: GatewayCallRecord
}

struct IncomingCallPush: Sendable {
    let callID: String
    let caller: String?
    let expiresAt: Date?

    nonisolated init?(dictionary: [AnyHashable: Any]) {
        guard dictionary["type"] as? String == "call.incoming",
              let callID = dictionary["call_id"] as? String,
              UUID(uuidString: callID) != nil else { return nil }
        self.callID = callID
        caller = dictionary["caller"] as? String
        if let rawExpiry = dictionary["expires_at"] as? String {
            expiresAt = Self.parseDate(rawExpiry)
        } else {
            expiresAt = nil
        }
    }

    nonisolated private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct LocalCallSession: Sendable {
    let callKitUUID: UUID
    var serverCallID: String
    var caller: String?
    var direction: GatewayCallDirection
    var record: GatewayCallRecord?
    var callKitReported = false
    var endedLocally = false
}
#endif
