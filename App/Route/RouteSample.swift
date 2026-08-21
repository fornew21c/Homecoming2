import CoreLocation
import Foundation

/// 경로 만들기를 화면 없이 한 번 돌린다. `-homecomingMakeRoute` 가 부른다.
///
/// **왜 필요한가** — 만들기 화면은 탭으로만 쓸 수 있는데, 실기기와 시뮬레이터에
/// 탭을 넣을 수단이 없다. 그래서 화면이 부르는 것과 같은 코드(`RouteTracer` →
/// `RouteStore.save`)를 인자로도 부를 수 있게 둔다.
///
/// 좌표는 실제 귀가 경로이고, 앱의 장소 검색이 준 값이다. 예전에는 지오코딩이
/// 실패해서 손으로 짐작한 값을 썼는데 **풍산역이 2km 어긋나 있었다.**
/// `Tools/routes/commute-sample.json` 도 그 값으로 만들어져 있었다.
@MainActor
enum RouteSample {

    /// 회사(회사) → 집. 구간 시간은 대중교통 앱이 알려 준 실측이다.
    ///
    /// **좌표는 공공데이터의 진짜 정류장 자리다.** 예전에는 손으로 짐작한 값을
    /// 썼는데 풍산역이 2km 어긋나 있었다.
    ///
    /// 집은 이 기기에 등록된 집을 쓴다. 하드코딩하면 남의 집으로 가는 경로가 된다.
    static func make(environment: HomecomingEnvironment, coordinator: HomecomingCoordinator) async {
        let origin = CLLocationCoordinate2D(latitude: 37.528676, longitude: 126.918861)
        guard let home = coordinator.home else {
            print("[귀가마중] 집이 등록되어 있지 않다. 먼저 집을 등록해라.")
            return
        }

        let steps: [RouteTracer.Step] = [
            step(.walk, "출발역.은행앞", 37.528479, 126.918068, 6),
            step(.wait, "163번 대기", nil, nil, 3),
            step(.bus, "환승로터리", 37.553809, 126.936883, 9, busNo: "163"),
            step(.walk, "서강대학교", 37.551100, 126.937970, 7),
            step(.wait, "경의중앙선 대기", nil, nil, 4),
            step(.subway, "풍산역", 37.674083, 126.786117, 31),
            step(.walk, "풍산역 정류장", 37.673850, 126.786033, 6),
            step(.wait, "999번 대기", nil, nil, 2),
            step(.bus, "아파트단지", 37.682450, 126.810783, 10, busNo: "999"),
            step(.walk, home.name, home.latitude, home.longitude, 3),
        ]

        do {
            var tracer = RouteTracer()
            tracer.busWaypoints = { no, from, fromName, toName in
                await environment.routes.busWaypoints(no: no, from: from,
                                                     fromName: fromName, toName: toName)
            }
            let plotted = try await tracer.plot(origin: origin, steps: steps)
            let legs = plotted.legs
            if !plotted.busFallbacks.isEmpty {
                print("[귀가마중] 노선 자료 없음 — 자동차 경로로 그린 버스: "
                      + plotted.busFallbacks.joined(separator: ", "))
            }
            for leg in legs {
                print("[귀가마중] 구간 \(leg.mode.rawValue) \(leg.seconds)초 "
                      + "startsAt=\(leg.startsAt) 점 \(leg.points.count) → \(leg.toName ?? "-")")
            }

            let draft = RouteDraft(name: "회사-집 (10구간)", home: home, legs: legs)
            guard let id = await environment.routes.save(draft) else {
                print("[귀가마중] 경로 저장 실패: \(environment.routes.lastError ?? "이유 없음")")
                return
            }
            coordinator.selectedRouteID = id
            print("[귀가마중] 경로 저장 \(id) · 총 \(draft.totalSeconds / 60)분 · 구간 \(legs.count)개")
        } catch {
            print("[귀가마중] 경로 만들기 실패: \(error.localizedDescription)")
        }
    }

    /// 실제 귀가 경로에 나오는 이름들로 장소 검색을 시험한다.
    ///
    /// 고르는 이름에 뜻이 있다. 지하철역(서강대역)·버스정류장(환승로터리)·
    /// 아파트 단지(아파트단지)는 각각 다른 종류의 장소이고, 정류장 이름이 제일
    /// 어렵다 — 지도 데이터에 시설로 등록되어 있지 않을 수 있다.
    static func probeSearch() async {
        let near = CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)
        let names = [
            "국회의사당역", "환승로터리", "서강대역",
            "풍산역", "아파트단지", "회사",
        ]

        let search = PlaceSearch()
        search.near = near

        for name in names {
            search.search(name)
            // `search` 는 손이 멈출 때까지 350ms 기다린 뒤 요청한다. 그것과
            // 왕복 시간을 합쳐 기다린다.
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(100))
                if !search.hits.isEmpty || search.lastError != nil { break }
            }

            if let hit = search.hits.first {
                let more = search.hits.count > 1 ? " (후보 \(search.hits.count)개)" : ""
                print(String(
                    format: "[귀가마중] 검색 %@ → %@ %.5f, %.5f · %@%@",
                    name, hit.name, hit.coordinate.latitude, hit.coordinate.longitude,
                    hit.context ?? "-", more
                ))
            } else {
                print("[귀가마중] 검색 \(name) → 못 찾음 · \(search.lastError ?? "이유 없음")")
            }
        }
        print("[귀가마중] 검색 시험 끝")
    }

    private static func step(
        _ mode: RouteLeg.Mode, _ name: String,
        _ lat: Double?, _ lon: Double?, _ minutes: Int,
        busNo: String? = nil
    ) -> RouteTracer.Step {
        RouteTracer.Step(
            mode: mode,
            toName: name,
            to: lat.flatMap { lat in lon.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) } },
            minutes: minutes,
            busNo: busNo
        )
    }
}
