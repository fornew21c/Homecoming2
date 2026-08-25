import CoreLocation
import Foundation

/// 귀가 한 건 — **세션** — 을 서버에 보고한다.
///
/// 세션은 귀가 시작을 누른 순간부터 도착(또는 중지)까지의 한 건이다.
/// 서버가 시작·위치·종료·가족 각자에게 보내는 일을 하나로 묶으려면 이 단위에 ID 가 있어야 한다.
///
/// **이게 없으면 가족은 아무것도 못 본다.** 귀가자 기기가 아무리 정확히 계산해도
/// 그 값은 자기 화면에만 남는다. 서버가 알아야 가족 기기로 보낼 수 있다.
///
/// 형식은 `docs/API-SPEC.md` 3.3 세션.
protocol SessionReporting: Sendable {

    /// 귀가 시작을 누른 순간. 서버는 이때 가족들에게 push-to-start 를 보낸다.
    func start(_ request: SessionStartRequest) async throws -> String

    /// 위치 보고. 서버가 ETA·도착을 판정하고 가족 화면을 갱신한다.
    /// 위치를 보내고, **서버가 그 자리로 다시 계산한 상태를 받아 온다.**
    ///
    /// 돌려주는 값이 nil 이면 서버가 상태를 안 줬다는 뜻이다(옛 서버이거나
    /// 도착 처리로 세션이 닫힌 경우). 그때는 지금까지처럼 푸시를 기다린다.
    func report(sessionID: String, location: SessionLocation) async throws
        -> HomecomingAttributes.ContentState?

    /// 도착했거나 사용자가 껐다.
    func end(sessionID: String, reason: SessionEndReason) async throws
}

// MARK: - 요청 형태

struct SessionStartRequest: Encodable, Sendable {

    struct Home: Encodable, Sendable {
        let lat: Double
        let lon: Double
        let arrivalRadius: Double
        let name: String

        init(_ place: HomePlace) {
            lat = place.latitude
            lon = place.longitude
            arrivalRadius = place.arrivalRadius
            name = place.name
        }
    }

    let home: Home
    let travelerName: String
    let safetyMode: Bool

    /// 저장된 경로로 도는 귀가면 그 경로 id.
    ///
    /// 있으면 도착예정이 그 경로의 실측 소요시간에서 나온다. 집 좌표도 경로에 있으니
    /// 서버가 그쪽을 쓴다 — 두 곳에 적어 두면 어긋날 자리가 생긴다.
    var routeId: String?

    /// 경로 없이 도는 귀가에서 **귀가자가 적은** 예상 소요시간(분).
    ///
    /// 서버가 `planned_seconds` 로 저장하고 도착예정을 `출발 시각 + 이 시간` 으로
    /// 고정한다 — 위치로 흔들지 않는다. 저장된 경로의 실측 소요시간을 쓰는 것과
    /// 같은 자리다(둘 다 추정이 아니라 아는 값이다).
    ///
    /// **경로가 있으면 보내지 않는다.** 서버는 경로가 있으면 이 값을 아예 보지
    /// 않지만, 보내는 쪽에서 비워 두면 "무엇이 도착예정의 주인인가" 가 요청만 봐도
    /// 드러난다.
    var plannedMinutes: Int?

    /// 출발 좌표. **가족 카드가 처음 뜰 때 지도를 그리는 값이다.**
    ///
    /// 서버는 좌표가 있을 때만 갱신값에 실어 보낸다. 예전에는 위치 보고가 한 건
    /// 올라오기 전까지 그 값이 비어 있어서, 가족은 카드는 받았는데 지도가 없는
    /// 화면을 봤다 — 1초 뒤 메워지지만 그 사이를 보면 고장으로 읽힌다.
    ///
    /// 첫 픽스를 못 받은 상태로 시작하면 nil 이다. 그때는 예전처럼 첫 위치 보고에서
    /// 메워진다.
    var lat: Double?
    var lon: Double?

    /// `[P2]` 안전귀가일 때만 의미가 있다.
    let checkInInterval: Double?
}

struct SessionLocation: Encodable, Sendable {
    let lat: Double
    let lon: Double
    let accuracy: Double
    let at: String

    init(_ location: CLLocation) {
        lat = location.coordinate.latitude
        lon = location.coordinate.longitude
        accuracy = location.horizontalAccuracy
        at = HomecomingWire.string(from: location.timestamp)
    }
}

enum SessionEndReason: String, Encodable, Sendable {
    /// 집에 도착했다.
    case arrived
    /// 사용자가 공유를 껐다. **도착과 반드시 구분되어야 한다** —
    /// 가족 화면에서 조용해진 이유를 모르면 안전귀가라고 할 수 없다.
    case stopped
}

// MARK: - 실제 서버

struct RemoteSessionReporter: SessionReporting {

    let baseURL: URL
    var session: URLSession = .shared
    var auth: HomecomingAuth

    /// 위치 보고는 늦으면 의미가 없다. 오래 기다리느니 다음 것을 보내는 편이 낫다.
    var timeout: TimeInterval = 8

    func start(_ request: SessionStartRequest) async throws -> String {
        let data = try await post("session/start", body: request)
        struct Response: Decodable { let sessionId: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw SessionError.badResponse(-1)
        }
        return response.sessionId
    }

    func report(sessionID: String, location: SessionLocation) async throws
        -> HomecomingAttributes.ContentState? {
        let data = try await post("session/\(sessionID)/location", body: location)
        // **못 읽어도 실패가 아니다.** 위치는 이미 닿았고, 상태는 덤이다.
        // 이 필드를 모르는 서버도 있고, 도착으로 세션이 닫히면 안 온다.
        struct Response: Decodable { let state: HomecomingAttributes.ContentState? }
        return try? JSONDecoder().decode(Response.self, from: data).state
    }

    func end(sessionID: String, reason: SessionEndReason) async throws {
        struct Body: Encodable { let reason: SessionEndReason }
        _ = try await post("session/\(sessionID)/end", body: Body(reason: reason))
    }

    private func post<T: Encodable>(_ path: String, body: T) async throws -> Data {
        let (data, http) = try await auth.send(baseURL: baseURL, session: session) {
            var request = URLRequest(url: baseURL.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
            return request
        }
        guard (200..<300).contains(http.statusCode) else {
            // 404 는 "그 세션 없다" 다. 다른 오류와 달리 다시 보내도 영영 안 된다.
            if http.statusCode == 404 { throw SessionError.gone }
            throw SessionError.badResponse(http.statusCode)
        }
        return data
    }
}

// MARK: - 서버가 없을 때

/// 아무 데도 보내지 않는다. 서버 주소가 비어 있으면 이쪽이 쓰인다.
///
/// 이 경우 귀가 알림은 **본인 기기에만** 뜬다. 가족은 못 본다.
struct LocalOnlySessionReporter: SessionReporting {

    func start(_ request: SessionStartRequest) async throws -> String {
        HomecomingLog.push.notice("서버 미연결 — 이 귀가는 본인 기기에만 표시됩니다")
        return "local"
    }

    func report(sessionID: String, location: SessionLocation) async throws
        -> HomecomingAttributes.ContentState? { nil }
    func end(sessionID: String, reason: SessionEndReason) async throws {}
}

enum SessionError: LocalizedError {
    case badResponse(Int)

    /// 서버에 그 세션이 없다.
    ///
    /// 앱은 세션 ID 를 저장해 두고 재시작 때 이어간다 — 그게 없으면 앱이 한 번
    /// 죽을 때 가족 화면이 마지막 값에서 멈춘다. 하지만 서버가 그 세션을 끝냈으면
    /// (도착 처리, 24시간 뒤 정리, 다른 기기에서 중지) 앱만 모르는 상태가 된다.
    /// 그대로 두면 위치를 죽은 세션으로 계속 보내고 가족은 아무것도 못 본다.
    /// 그래서 이 오류는 "저 ID 를 버리고 새로 시작하라" 는 신호로 다룬다.
    case gone

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "세션 서버 응답 오류 (\(code))"
        case .gone:                  return "서버에서 끝난 귀가입니다."
        }
    }
}
