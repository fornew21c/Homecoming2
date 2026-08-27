import CoreLocation
import Foundation
import Observation

/// 저장된 귀가 경로를 화면에 들고 있는다.
///
/// 경로는 서버에만 존재한다. 기기는 그 사본을 보여 줄 뿐이라 화면을 열 때마다 다시 읽는다.
/// 페어링과 같은 방침이다 — 기기가 진실을 들고 있으면 두 곳이 어긋난다.
@MainActor
@Observable
final class RouteStore {

    private let client: RouteClient

    /// 서버가 붙어 있는지. 없으면 경로 기능 자체가 불가능하다.
    let isAvailable: Bool

    private(set) var routes: [HomecomingRoute] = []
    private(set) var isWorking = false
    private(set) var lastError: String?

    init(client: RouteClient, isAvailable: Bool) {
        self.client = client
        self.isAvailable = isAvailable
    }

    // MARK: - 읽기

    func refresh() async {
        guard isAvailable else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            routes = try await client.routes()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// id 로 경로를 찾는다. 고른 경로를 화면에 보여 줄 때 쓴다.
    func route(id: String?) -> HomecomingRoute? {
        guard let id else { return nil }
        return routes.first { $0.id == id }
    }

    /// 이름으로 찾은 버스정류장. 실패하면 빈 목록이다.
    func stopsNamed(_ text: String) async -> [BusStop] {
        guard isAvailable else { return [] }
        return (try? await client.stops(named: text)) ?? []
    }

    /// 이 좌표 근처의 진짜 버스정류장. 실패하면 빈 목록이다 —
    /// 이게 없어도 지도에서 찍어 경로를 만들 수 있어야 한다.
    func nearbyStops(_ coordinate: CLLocationCoordinate2D) async -> [BusStop] {
        guard isAvailable else { return [] }
        return (try? await client.stops(near: coordinate)) ?? []
    }

    /// 버스 한 구간이 지나는 정류장 좌표. 실패하면 빈 배열 — 그때는 자동차 경로다.
    func busWaypoints(no: String, from: CLLocationCoordinate2D,
                      to: CLLocationCoordinate2D,
                      fromName: String, toName: String) async -> [CLLocationCoordinate2D] {
        guard isAvailable else { return [] }
        return (try? await client.busWaypoints(no: no, from: from, to: to,
                                              fromName: fromName, toName: toName)) ?? []
    }

    /// 지하철 한 구간이 지나는 역 좌표. 실패하면 빈 배열 — 그때는 두 역 직선이다.
    func subwayWaypoints(fromName: String, toName: String) async -> [CLLocationCoordinate2D] {
        guard isAvailable else { return [] }
        return (try? await client.subwayWaypoints(fromName: fromName, toName: toName)) ?? []
    }

    // MARK: - 저장

    /// 경로를 저장하고 그 id 를 돌려준다. 실패하면 nil 이고 `lastError` 에 이유가 남는다.
    /// 고칠 경로를 통째로 읽는다. 실패하면 nil 이고 `lastError` 에 이유가 남는다.
    func detail(of routeID: String) async -> RouteDetail? {
        guard isAvailable else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let detail = try await client.route(id: routeID)
            lastError = nil
            return detail
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// 경로를 지운다. 잘못 만든 것을 못 지우면 고르기 화면이 쓰레기로 찬다.
    func delete(_ routeID: String) async -> Bool {
        guard isAvailable else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.delete(id: routeID)
            lastError = nil
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func save(_ draft: RouteDraft, replacing routeID: String? = nil) async -> String? {
        guard isAvailable else {
            lastError = "서버가 연결되어 있지 않습니다."
            return nil
        }
        guard draft.isSavable else {
            // 이동 구간에 좌표가 없으면 서버가 "지금 어느 구간" 을 판정할 수 없다.
            // 저장은 되겠지만 도착예정이 위치를 못 쓰게 되니 미리 막는다.
            lastError = "이름과 좌표가 있는 이동 구간이 최소 하나 필요합니다."
            return nil
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let id = try await client.save(draft, replacing: routeID)
            lastError = nil
            await refresh()
            return id
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
