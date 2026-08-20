import CoreLocation
import Foundation

/// 자주 가는 귀가 경로를 서버에 두고 쓴다.
///
/// **도착예정은 계산할 값이 아니라 아는 값이다.** 매일 같은 버스-지하철-버스를 타면
/// 대중교통 앱이 "1시간 21분" 이라고 알려 준다. 그걸 저장해 두면 위치가 부정확한
/// 지하철 구간에서도 도착예정이 흔들리지 않는다.
///
/// 위치가 하는 일은 두 가지로 줄어든다 — 지금 어느 구간인가, 얼마나 밀렸는가.
/// 둘 다 남은 시간을 예측하는 것보다 훨씬 쉽고 정확하다.
///
/// 형식은 `docs/API-SPEC.md`.
protocol RouteClient: Sendable {

    /// 저장해 둔 경로 목록.
    func routes() async throws -> [HomecomingRoute]

    /// 경로 하나를 통째로. 고치려면 구간을 되돌려받아야 한다 —
    /// 목록은 요약만 준다.
    func route(id: String) async throws -> RouteDetail

    /// 경로를 저장한다. 돌려받은 id 를 귀가 시작에 넘긴다.
    ///
    /// `replacing` 이 있으면 그 경로를 **고친다.** 이름으로만 찾으면 이름을 바꾼
    /// 순간 새 경로가 생기고 옛것이 남는다 — 고쳤다고 생각한 사람에게 두 개가 보인다.
    func save(_ draft: RouteDraft, replacing routeID: String?) async throws -> String

    /// 경로를 지운다. 잘못 만든 것을 못 지우면 고르기 화면이 쓰레기로 찬다.
    func delete(id: String) async throws

    /// 이 좌표 근처의 진짜 버스정류장.
    ///
    /// 애플 지도에는 정류장이 시설로 없어서 "환승로터리" 를 검색하면 근처 편의점이
    /// 나온다. 지도에서 대충 찍은 자리를 여기 물으면 공식 이름과 정확한 좌표로
    /// 바꿔 준다. 서버가 공공데이터를 대신 부른다 — 서비스 키는 서버에만 둔다.
    func stops(near coordinate: CLLocationCoordinate2D) async throws -> [BusStop]

    /// 이름으로 정류장을 찾는다. 애플 지도가 모르는 이름을 공공데이터는 안다.
    func stops(named text: String) async throws -> [BusStop]

    /// 버스 한 구간이 실제로 지나는 정류장 좌표. 빈 배열이면 그릴 것이 없다.
    ///
    /// 노선 자료가 서버에만 있어서(공공데이터 키가 서버에 있다) 이쪽으로 묻는다.
    /// 서울 시내버스는 이 자료에 없으므로 빈 배열이 정상 응답이다.
    func busWaypoints(no: String, from: CLLocationCoordinate2D,
                      fromName: String, toName: String) async throws -> [CLLocationCoordinate2D]
}

/// 저장된 경로의 전체 내용. 고칠 때 쓴다.
struct RouteDetail: Sendable, Identifiable {
    let id: String
    let name: String
    let home: HomePlace
    let legs: [RouteLeg]

    /// 편집기가 다루는 모양으로 되돌린다.
    ///
    /// 구간의 도착 좌표는 좌표열의 **마지막 점**이다. 대기 구간은 자리가 바뀌지
    /// 않으니 좌표가 없다.
    var steps: [RouteTracer.Step] {
        legs.map { leg in
            RouteTracer.Step(
                mode: leg.mode,
                toName: leg.toName ?? "",
                to: leg.mode.moves ? leg.points.last.map {
                    CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1])
                } : nil,
                minutes: max(1, leg.seconds / 60),
                busNo: leg.busNo
            )
        }
    }

    /// 경로의 출발 자리. 첫 구간 좌표열의 첫 점이다.
    var origin: CLLocationCoordinate2D? {
        for leg in legs {
            if let first = leg.points.first {
                return CLLocationCoordinate2D(latitude: first[0], longitude: first[1])
            }
        }
        return nil
    }
}

/// 공공데이터가 아는 버스정류장 하나.
struct BusStop: Sendable, Identifiable, Equatable {
    let name: String
    let coordinate: CLLocationCoordinate2D
    /// 정류장 기둥에 적힌 번호. 같은 이름이 여럿일 때 사람이 구분하는 값이다.
    let number: Int?

    var id: String { "\(name)-\(coordinate.latitude)-\(coordinate.longitude)" }

    static func == (a: BusStop, b: BusStop) -> Bool { a.id == b.id }
}

// MARK: - 모델

/// 서버에 저장된 경로의 요약. 고르는 데 필요한 만큼만 담는다.
struct HomecomingRoute: Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    /// 이 경로로 집까지 걸리는 시간. 도착예정의 근거다.
    let totalSeconds: Int
    let homeName: String?

    /// 첫 구간의 교통수단과 문구.
    ///
    /// **귀가를 시작하는 순간의 카드를 앱이 직접 만들기 때문에 필요하다.**
    /// 서버 응답을 기다리지 않으므로, 이게 없으면 MapKit 이 준 자동차 경로를
    /// 쓰게 된다 — 걸어서 역까지 가는 첫 6분에 카드가 "차량 탑승" 으로 떴다.
    let firstTransport: HomecomingAttributes.Transport?
    let firstDetail: String?
    /// 경로를 따라간 전체 길이(m). 진행 바의 분모다.
    let totalMeters: Int?

    /// 노선도에 그릴 정류장 목록.
    ///
    /// **목록 응답에서 온다.** 앱은 귀가 시작 순간의 액티비티를 직접 만들고
    /// 서버 응답을 기다리지 않는다(`activity.start()` 가 `openSession()` 보다
    /// 먼저다). 그래서 세션 응답으로는 늦다. `firstTransport` 가 여기 있는
    /// 이유와 같다.
    let stops: [HomecomingAttributes.RouteShape.Stop]?

    /// "1시간 21분" 처럼 읽히는 소요시간.
    var durationText: String {
        let minutes = max(1, totalSeconds / 60)
        if minutes < 60 { return "\(minutes)분" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)시간" : "\(hours)시간 \(rest)분"
    }
}

/// 경로 한 구간.
///
/// 좌표열(`points`)이 있어야 서버가 "지금 이 구간에 있다" 를 판정할 수 있다.
/// 구간이 km 단위라 위치 정확도가 150m 여도 맞힌다.
struct RouteLeg: Sendable, Equatable, Codable {

    enum Mode: String, Sendable, Codable, CaseIterable {
        case walk, bus, subway, car
        /// 환승 대기. 위치는 그대로고 시간만 흐른다.
        case wait

        var title: String {
            switch self {
            case .walk:   return "도보"
            case .bus:    return "버스"
            case .subway: return "지하철"
            case .car:    return "자동차"
            case .wait:   return "환승 대기"
            }
        }

        /// 이동하는 구간인지. 대기는 좌표가 필요 없다.
        var moves: Bool { self != .wait }
    }

    var mode: Mode
    /// 출발부터 이 구간이 시작되기까지의 초.
    var startsAt: Int
    /// 이 구간에 걸리는 초. **대중교통 앱의 실측을 그대로 넣는다.**
    var seconds: Int
    /// 도착 지점 이름. 가족 카드가 "풍산역까지 12분" 을 말할 수 있게 하는 값이다.
    var toName: String?
    /// 구간 경로의 좌표열. `[[위도, 경도], ...]`
    var points: [[Double]]

    /// 버스 노선번호. 버스 구간에만 있고, 없어도 된다.
    ///
    /// 좌표열은 이미 이 번호로 그려져 저장돼 있다. 그래도 함께 남기는 이유는
    /// **경로를 고칠 때 되살려야** 하기 때문이다 — 없으면 한 번 고치는 순간
    /// 노선번호가 사라지고 그 구간이 자동차 경로로 되돌아간다.
    var busNo: String?

    // 서버는 `label` 도 함께 보내는데 그건 `mode` 에서 나오는 값이라 읽지 않는다.
    private enum CodingKeys: String, CodingKey {
        case mode, startsAt, seconds, toName, points, busNo
    }

    /// 서버로 보낼 표현. 서버는 label 도 읽으므로 함께 넣는다.
    var wire: [String: Any] {
        var out: [String: Any] = [
            "mode": mode.rawValue,
            "label": mode.title,
            "startsAt": startsAt,
            "seconds": seconds,
            "points": points,
        ]
        if let toName { out["toName"] = toName }
        if let busNo, !busNo.isEmpty { out["busNo"] = busNo }
        return out
    }
}

/// 저장하려는 경로.
struct RouteDraft: Sendable, Equatable {
    var name: String
    var home: HomePlace
    var legs: [RouteLeg]

    /// 전체 소요시간. 마지막 구간이 끝나는 시각이다.
    var totalSeconds: Int {
        legs.map { $0.startsAt + $0.seconds }.max() ?? 0
    }

    /// 저장할 수 있는 상태인지. 좌표 없는 이동 구간만 있으면 서버가 구간을 못 찾는다.
    var isSavable: Bool {
        !name.isEmpty
            && totalSeconds > 0
            && legs.contains { $0.mode.moves && !$0.points.isEmpty }
    }
}

enum RouteError: LocalizedError {
    case unavailable
    case badResponse(Int)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:            return "서버가 연결되지 않았습니다."
        case .badResponse(let code):  return "경로 서버 응답 오류 (\(code))"
        case .rejected(let reason):   return reason
        }
    }
}

// MARK: - 실제 서버

struct RemoteRouteClient: RouteClient {

    let baseURL: URL
    var session: URLSession = .shared
    var auth: HomecomingAuth
    var timeout: TimeInterval = 10

    func routes() async throws -> [HomecomingRoute] {
        struct Row: Decodable {
            let routeId: String
            let name: String
            let totalSeconds: Int
            let homeName: String?
            let firstTransport: String?
            let firstDetail: String?
            let totalMeters: Int?
            let stops: [HomecomingAttributes.RouteShape.Stop]?
        }
        let rows: [Row] = try await get("route")
        return rows.map {
            HomecomingRoute(
                id: $0.routeId, name: $0.name,
                totalSeconds: $0.totalSeconds, homeName: $0.homeName,
                firstTransport: $0.firstTransport.flatMap(HomecomingAttributes.Transport.init(rawValue:)),
                firstDetail: $0.firstDetail,
                totalMeters: $0.totalMeters,
                stops: $0.stops
            )
        }
    }

    func route(id: String) async throws -> RouteDetail {
        struct Row: Decodable {
            struct Home: Decodable {
                let lat: Double; let lon: Double; let name: String?; let radius: Double?
            }
            let routeId: String
            let name: String
            let home: Home
            let legs: [RouteLeg]
        }
        let row: Row = try await get("route/\(id)")
        return RouteDetail(
            id: row.routeId,
            name: row.name,
            home: HomePlace(
                name: row.home.name ?? "집",
                coordinate: CLLocationCoordinate2D(latitude: row.home.lat, longitude: row.home.lon),
                arrivalRadius: row.home.radius ?? 120
            ),
            legs: row.legs
        )
    }

    func save(_ draft: RouteDraft, replacing routeID: String?) async throws -> String {
        // 구간의 좌표열이 중첩 배열이라 Codable 로 표현하기보다 딕셔너리가 짧다.
        var payload: [String: Any] = [
            "name": draft.name,
            "totalSeconds": draft.totalSeconds,
            "home": [
                "lat": draft.home.latitude,
                "lon": draft.home.longitude,
                "name": draft.home.name,
                "radius": draft.home.arrivalRadius,
            ],
            "legs": draft.legs.map(\.wire),
        ]
        // 고치는 것이면 id 를 함께 보낸다. 이름으로만 찾으면 이름을 바꾼 순간
        // 새 경로가 생기고 옛것이 남는다.
        if let routeID { payload["routeId"] = routeID }

        let (data, http) = try await auth.send(baseURL: baseURL, session: session) {
            var request = URLRequest(url: url(for: "route"))
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            return request
        }

        struct Saved: Decodable { let routeId: String }
        struct Failure: Decodable { let error: String }

        guard (200..<300).contains(http.statusCode) else {
            // 서버는 왜 거절했는지 말해 준다. 그 문구가 사용자에게 제일 쓸모 있다.
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
                throw RouteError.rejected(failure.error)
            }
            throw RouteError.badResponse(http.statusCode)
        }
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
            throw RouteError.badResponse(-2)
        }
        return saved.routeId
    }

    func delete(id: String) async throws {
        let (_, http) = try await auth.send(baseURL: baseURL, session: session) {
            var request = URLRequest(url: url(for: "route/\(id)"))
            request.httpMethod = "DELETE"
            request.timeoutInterval = timeout
            return request
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RouteError.badResponse(http.statusCode)
        }
    }

    func stops(near coordinate: CLLocationCoordinate2D) async throws -> [BusStop] {
        struct Response: Decodable {
            struct Stop: Decodable {
                let name: String; let lat: Double; let lon: Double; let no: Int?
            }
            let stops: [Stop]
        }
        let path = String(format: "stops?lat=%.6f&lon=%.6f", coordinate.latitude, coordinate.longitude)
        let response: Response = try await get(path)
        return response.stops.map {
            BusStop(name: $0.name,
                    coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                    number: $0.no)
        }
    }

    func busWaypoints(no: String, from: CLLocationCoordinate2D,
                      fromName: String, toName: String) async throws -> [CLLocationCoordinate2D] {
        struct Response: Decodable {
            let points: [[Double]]
            /// 좌표를 못 찾은 정류장 이름. 조용히 빠지지 않게 서버가 알려 준다.
            let missing: [String]?
        }
        func escape(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        }
        let path = String(format: "bus/leg?no=%@&from=%@&to=%@&fromLat=%.6f&fromLon=%.6f",
                          escape(no), escape(fromName), escape(toName),
                          from.latitude, from.longitude)
        // **다른 요청보다 넉넉히 기다린다.** 서버가 노선표를 아직 안 받아 뒀으면
        // 시도 전체를 훑어야 하고(경기 4,671개, 15초), 정류장 좌표도 이름마다
        // 한 번씩 묻는다. 10초에 끊으면 그 구간이 조용히 자동차 경로로 저장된다.
        // 경로를 저장할 때 한 번 있는 일이라 사용자가 기다릴 만한 자리다.
        let response: Response = try await get(path, timeout: 45)
        if let missing = response.missing, !missing.isEmpty {
            HomecomingLog.push.notice(
                "버스 \(no, privacy: .public) 경유 정류장 좌표 일부 없음: \(missing.joined(separator: ", "), privacy: .public)")
        }
        return response.points.compactMap {
            $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil
        }
    }

    func stops(named text: String) async throws -> [BusStop] {
        guard let escaped = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              !escaped.isEmpty
        else { return [] }
        struct Response: Decodable {
            struct Stop: Decodable {
                let name: String; let lat: Double; let lon: Double; let ars: String?
            }
            let stops: [Stop]
        }
        let response: Response = try await get("stops?q=\(escaped)")
        return response.stops.map {
            BusStop(name: $0.name,
                    coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                    number: $0.ars.flatMap(Int.init))
        }
    }

    /// 질의 문자열이 붙은 경로도 받는다.
    ///
    /// `appendingPathComponent` 만 쓰면 `?` 가 경로의 일부로 인코딩돼서
    /// `/stops%3Flat=…` 가 된다. 서버는 그런 경로를 모른다.
    private func url(for path: String) -> URL {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var components = URLComponents(
            url: baseURL.appendingPathComponent(String(parts[0])),
            resolvingAgainstBaseURL: false
        )
        // **이미 인코딩된 질의**를 그대로 넣는다. `query` 에 넣으면 한 번 더
        // 인코딩돼서 "서강" 이 `%25EC%2584%259C` 가 된다(%25 는 % 를 인코딩한 것).
        // 서버는 그 글자를 이름으로 찾고 당연히 못 찾는다 — 오류도 안 난다.
        if parts.count > 1 { components?.percentEncodedQuery = String(parts[1]) }
        return components?.url ?? baseURL.appendingPathComponent(path)
    }

    /// `timeout` 을 따로 받는 이유는 요청마다 기다릴 만한 시간이 다르기 때문이다.
    /// 목록 조회는 빨라야 하고, 버스 노선 조회는 공공데이터를 여러 번 거친다.
    private func get<Response: Decodable>(
        _ path: String, timeout: TimeInterval? = nil
    ) async throws -> Response {
        let (data, http) = try await auth.send(baseURL: baseURL, session: session) {
            var request = URLRequest(url: url(for: path))
            request.httpMethod = "GET"
            request.timeoutInterval = timeout ?? self.timeout
            return request
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RouteError.badResponse(http.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw RouteError.badResponse(-2)
        }
        return decoded
    }
}

// MARK: - 서버 없이

/// 서버가 없으면 경로 기능을 쓸 수 없다. 조용히 비어 있는 것보다 이유를 말해야 한다.
struct UnavailableRouteClient: RouteClient {
    func routes() async throws -> [HomecomingRoute] { [] }
    func route(id: String) async throws -> RouteDetail { throw RouteError.unavailable }
    func save(_ draft: RouteDraft, replacing routeID: String?) async throws -> String {
        throw RouteError.unavailable
    }
    func delete(id: String) async throws { throw RouteError.unavailable }
    func stops(near coordinate: CLLocationCoordinate2D) async throws -> [BusStop] { [] }
    func stops(named text: String) async throws -> [BusStop] { [] }
    func busWaypoints(no: String, from: CLLocationCoordinate2D,
                      fromName: String, toName: String) async throws -> [CLLocationCoordinate2D] { [] }
}
