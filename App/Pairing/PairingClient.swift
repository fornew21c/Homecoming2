import Foundation

/// 누가 내 귀가를 볼 수 있는지 정한다.
///
/// **승인 주체는 귀가자다.** 가족이 일방적으로 붙을 수 있으면 이건 감시 도구가 된다.
/// 귀가자가 초대 코드를 만들어 건네고, 언제든 혼자 끊을 수 있어야 한다.
///
/// 형식은 `docs/API-SPEC.md` 3.2 페어링.
protocol PairingClient: Sendable {

    /// 귀가자가 초대 코드를 만든다.
    ///
    /// 이름을 함께 보낸다. 가족은 코드를 입력하는 순간 자기가 누구를 지켜보게 되는지
    /// 알아야 하는데, 서버는 그 이름을 여기서밖에 알 수 없다.
    func invite(travelerName: String) async throws -> PairInvite

    /// 가족이 코드를 입력해 연결한다.
    func accept(code: String, myName: String) async throws -> PairLink

    /// 나를 보고 있는 가족 목록 (귀가자 화면).
    func watchers() async throws -> [PairMember]

    /// 내가 보고 있는 사람 목록 (가족 화면).
    func watching() async throws -> [PairMember]

    /// 연결을 끊는다. 양쪽 다 자기 쪽에서 끊을 수 있다.
    func unlink(accountID: String) async throws
}

// MARK: - 모델

struct PairInvite: Sendable, Equatable {
    let code: String
    let expiresAt: Date

    /// 코드가 아직 살아 있는지.
    var isValid: Bool { expiresAt > Date() }
}

struct PairMember: Sendable, Identifiable, Equatable {
    let accountID: String
    let name: String

    var id: String { accountID }
}

struct PairLink: Sendable, Equatable {
    /// 이제 이 사람의 귀가를 보게 된다.
    let travelerName: String
    let travelerAccountID: String
}

enum PairingError: LocalizedError {
    case badResponse(Int)
    case invalidCode
    case expired

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "페어링 서버 응답 오류 (\(code))"
        case .invalidCode:           return "코드를 찾을 수 없습니다. 다시 확인해 주세요."
        case .expired:               return "만료된 코드입니다. 새로 받아 주세요."
        }
    }
}

// MARK: - 실제 서버

struct RemotePairingClient: PairingClient {

    let baseURL: URL
    var session: URLSession = .shared
    var auth: HomecomingAuth
    var timeout: TimeInterval = 10

    func invite(travelerName: String) async throws -> PairInvite {
        struct Body: Encodable { let travelerName: String }
        struct Response: Decodable { let code: String; let expiresAt: String }
        let body: Response = try await send(
            "pair/invite", method: "POST", body: Body(travelerName: travelerName)
        )
        guard let expires = HomecomingWire.date(from: body.expiresAt) else {
            throw PairingError.badResponse(-1)
        }
        return PairInvite(code: body.code, expiresAt: expires)
    }

    func accept(code: String, myName: String) async throws -> PairLink {
        struct Body: Encodable { let code: String; let name: String }
        struct Response: Decodable { let travelerName: String; let travelerAccountId: String }
        let body: Response = try await send(
            "pair/accept", method: "POST",
            body: Body(code: code.uppercased(), name: myName)
        )
        return PairLink(travelerName: body.travelerName, travelerAccountID: body.travelerAccountId)
    }

    func watchers() async throws -> [PairMember] {
        try await members(at: "pair/watchers")
    }

    func watching() async throws -> [PairMember] {
        try await members(at: "pair/watching")
    }

    func unlink(accountID: String) async throws {
        let _: EmptyResponse = try await send(
            "pair/link/\(accountID)", method: "DELETE", body: EmptyBody()
        )
    }

    // MARK: 전송

    private func members(at path: String) async throws -> [PairMember] {
        struct Row: Decodable { let accountId: String; let name: String }
        let rows: [Row] = try await send(path, method: "GET", body: EmptyBody())
        return rows.map { PairMember(accountID: $0.accountId, name: $0.name) }
    }

    private struct EmptyBody: Encodable {}
    private struct EmptyResponse: Decodable {}

    private func send<Body: Encodable, Response: Decodable>(
        _ path: String,
        method: String,
        body: Body
    ) async throws -> Response {
        let (data, response) = try await auth.send(baseURL: baseURL, session: session) {
            var request = URLRequest(url: baseURL.appendingPathComponent(path))
            request.httpMethod = method
            request.timeoutInterval = timeout
            if method != "GET" {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(body)
            }
            return request
        }
        guard let http = response as? HTTPURLResponse else { throw PairingError.badResponse(-1) }

        switch http.statusCode {
        case 200..<300: break
        case 404:       throw PairingError.invalidCode
        case 410:       throw PairingError.expired
        default:        throw PairingError.badResponse(http.statusCode)
        }

        if Response.self == EmptyResponse.self { return EmptyResponse() as! Response }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw PairingError.badResponse(-2)
        }
        return decoded
    }
}

// MARK: - 서버가 없을 때

/// 서버 없이는 페어링이 성립하지 않는다. 연결은 서버에만 존재하기 때문이다.
struct UnavailablePairingClient: PairingClient {
    private var unavailable: PairingError { .badResponse(0) }

    func invite(travelerName: String) async throws -> PairInvite { throw unavailable }
    func accept(code: String, myName: String) async throws -> PairLink { throw unavailable }
    func watchers() async throws -> [PairMember] { [] }
    func watching() async throws -> [PairMember] { [] }
    func unlink(accountID: String) async throws {}
}
