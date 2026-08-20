import CoreLocation
import Foundation
import Observation

/// 가족 지도에 그릴 경로 — 좌표열과 정류장.
struct RouteGeometry: Sendable {

    /// `Equatable` 을 붙이지 않는다 — `CLLocationCoordinate2D` 가 그 준수를
    /// 갖지 않아서 손으로 써야 하는데, 비교하는 곳이 없다. `ForEach` 는
    /// `Identifiable` 만 쓴다.
    struct Stop: Sendable, Identifiable {
        let name: String
        /// `walk` / `bus` / `subway` / `car`. **낱말 그대로 받는다** —
        /// `RouteShape.Stop.mode` 와 같은 이유로 열거형으로 바꾸지 않는다.
        let mode: String
        let coordinate: CLLocationCoordinate2D
        /// 여기서 갈아타며 기다리는 시간(초). 0 이 아니면 환승 지점이다.
        let waitSeconds: Int

        var isTransfer: Bool { waitSeconds > 0 }

        /// 지도에 찍을 아이콘. **카드·잠금화면과 같은 표를 쓴다** —
        /// 화면마다 다른 그림을 쓰면 같은 정류장이 달라 보인다.
        /// 모르는 낱말이 오면 버스로 둔다(서버가 새 수단을 보낼 수 있다).
        var symbolName: String {
            HomecomingAttributes.Transport(rawValue: mode)?.symbolName ?? "bus.fill"
        }
        var id: String { "\(name)-\(coordinate.latitude)-\(coordinate.longitude)" }
    }

    /// 구간 하나의 좌표열. **도보만 점선으로 그리기 위해 나눠 받는다.**
    struct Segment: Sendable, Identifiable {
        let mode: String
        let points: [CLLocationCoordinate2D]
        /// 도보인가. 네이버 지도처럼 도보만 점선으로 그린다 — 탈것까지 패턴을
        /// 나누면 지나온/남은 구간의 진하기와 곱해져 화면이 시끄러워진다.
        var isWalk: Bool { mode == "walk" }
        let id: Int
    }

    /// 전체를 이어붙인 좌표열.
    ///
    /// `segments` 와 겹치는 값이지만 둘 다 들고 있다 — 카메라 계산과 지나온/남은
    /// 구간 나누기가 이 하나의 배열을 쓴다. 구간별로 쪼개서 같은 일을 하려면
    /// 코드가 두 배가 되는데 얻는 것이 없다.
    var polyline: [CLLocationCoordinate2D]
    var segments: [Segment]
    var stops: [Stop]

    /// 그릴 것이 있는가. 경로 없이 시작한 귀가는 다 비어 있다.
    var isEmpty: Bool { polyline.isEmpty && stops.isEmpty }
}

/// 가족 기기가 서버에서 경로를 받아 와 세션별로 보관한다.
///
/// **가족 기기가 서버에 무언가를 묻는 첫 자리다.** 지금까지 이 앱의 가족 쪽은
/// 액티비티 푸시만 받았다(`WatchingStore` 주석). 그 원칙을 여기서 깨는 이유는
/// 크기다 — 좌표열이 샘플 경로만 해도 5.9KB 라서 APNs 4KB 한도에 안 들어간다.
/// 억지로 실으면 노선도(정류장 목록)가 예산에서 밀려 잠금화면에서 조용히 사라진다.
///
/// 지도는 앱 화면에만 있고 앱은 요청을 보낼 수 있다. 그래서 한도가 있는 채널
/// 대신 한도가 없는 채널로 가져온다. 위젯은 그대로 푸시만 본다.
///
/// **귀가 한 건에 한 번만 받는다.** 경로는 귀가 중에 바뀌지 않는다. 갱신 푸시가
/// 올 때마다 다시 받으면 위치 보고 횟수만큼(실주행 165번) 요청이 나간다.
@MainActor
@Observable
final class RouteGeometryStore {

    private let baseURL: URL?
    private let auth: HomecomingAuth

    /// 세션 id → 받아 둔 경로. 빈 경로(경로 없이 시작한 귀가)도 넣는다 —
    /// 없는 것과 "없다고 확인한 것" 을 구분해야 다시 묻지 않는다.
    private var cache: [String: RouteGeometry] = [:]

    /// 지금 받고 있는 세션. 같은 세션을 두 번 부르지 않게 막는다 — 뷰가 다시
    /// 그려질 때마다 `.task` 가 도는데, 그때마다 요청이 나가면 안 된다.
    private var inFlight: Set<String> = []

    init(baseURL: URL?, auth: HomecomingAuth) {
        self.baseURL = baseURL
        self.auth = auth
    }

    func geometry(for sessionID: String) -> RouteGeometry? { cache[sessionID] }

    /// 없으면 받아 온다. 이미 있거나 받는 중이면 아무것도 하지 않는다.
    func load(sessionID: String) async {
        guard let baseURL, cache[sessionID] == nil, !inFlight.contains(sessionID) else { return }
        inFlight.insert(sessionID)
        defer { inFlight.remove(sessionID) }

        do {
            let (data, http) = try await auth.send(baseURL: baseURL) {
                var request = URLRequest(
                    url: baseURL.appendingPathComponent("session/\(sessionID)/route"))
                request.httpMethod = "GET"
                // 지도는 없어도 카드가 도는 화면이다. 오래 붙잡고 있을 이유가 없다.
                request.timeoutInterval = 10
                return request
            }
            guard http.statusCode == 200 else {
                // 404 는 남의 세션이거나 없는 세션이다. 서버가 둘을 구분해 주지
                // 않는다(일부러 그렇게 뒀다). 어느 쪽이든 그릴 것이 없다.
                HomecomingLog.eta.warning(
                    "경로 좌표 받기 실패 \(http.statusCode, privacy: .public) 세션=\(sessionID, privacy: .public)")
                return
            }
            cache[sessionID] = try Self.decode(data)
        } catch {
            HomecomingLog.eta.warning(
                "경로 좌표 받기 오류: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 디코딩

    private struct Wire: Decodable {
        struct Stop: Decodable {
            let name: String
            let mode: String
            let lat: Double
            let lon: Double
            let waitSeconds: Int
        }
        struct Segment: Decodable {
            let mode: String
            let points: [[Double]]
        }
        /// `[[lat, lon], ...]`. 이름 붙은 객체가 아니라 배열인 것은 크기 때문이다.
        let polyline: [[Double]]
        /// 옛 서버는 이 키를 안 보낸다. 없으면 구간 없이 한 줄로 그린다.
        let segments: [Segment]?
        let stops: [Stop]
    }

    private static func decode(_ data: Data) throws -> RouteGeometry {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        func coordinates(_ raw: [[Double]]) -> [CLLocationCoordinate2D] {
            // 두 값이 아닌 점은 버린다. 좌표가 깨진 한 점 때문에 선 전체를
            // 포기하는 것보다, 그 점만 빼고 그리는 편이 화면에 낫다.
            raw.compactMap {
                $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil
            }
        }
        return RouteGeometry(
            polyline: coordinates(wire.polyline),
            segments: (wire.segments ?? []).enumerated().compactMap { index, piece in
                let points = coordinates(piece.points)
                return points.count >= 2
                    ? RouteGeometry.Segment(mode: piece.mode, points: points, id: index)
                    : nil
            },
            stops: wire.stops.map {
                RouteGeometry.Stop(
                    name: $0.name,
                    mode: $0.mode,
                    coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                    waitSeconds: $0.waitSeconds)
            })
    }
}
