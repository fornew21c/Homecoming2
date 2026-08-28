import CoreLocation
import Foundation
import MapKit

/// 구간 목록에 좌표열을 채워 넣는다.
///
/// **애플은 대중교통 좌표열을 주지 않는다.** `MKDirections` 에 `.transit` 을 넣으면
/// 소요시간은 주지만 폴리라인은 주지 않는다. 그래서 근사한다 —
///
///   버스   자동차 경로로 대신한다. 버스는 도로를 따라가니 형태가 거의 같다.
///   지하철 역 좌표를 직선으로 잇는다. 지하철은 도로를 따르지 않고 곧게 간다.
///   도보   보행 경로를 그대로 쓴다.
///   대기   환승 대기. 좌표 하나로 충분하다. 위치는 그대로고 시간만 흐른다.
///
/// 이 근사가 통하는 이유는 좌표열의 용도가 **"지금 어느 구간인가"** 뿐이기 때문이다.
/// 구간이 km 단위라 수백 미터 어긋나도 구간을 맞힌다. 도착예정은 좌표에서 나오지
/// 않는다 — 사용자가 넣는 실측 시간에서 나온다.
///
/// 맥의 `Tools/route-make.py` 가 하던 일과 같다. 폰에서 하게 옮긴 것뿐이다.
struct RouteTracer {

    /// 지하철 직선 구간의 좌표 간격(m).
    ///
    /// 촘촘할 이유가 없다. 서버는 좌표열에서 "가장 가까운 점" 을 찾는 데만 쓰고,
    /// 이탈 판정 기준이 1km 다. 200m 면 충분하고, 촘촘하면 저장할 것만 늘어난다.
    var subwaySpacing: CLLocationDistance = 200

    /// 사용자가 화면에서 채우는 것. 좌표열은 여기에 없다 — 그게 이 타입이 할 일이다.
    struct Step: Identifiable, Equatable {
        let id: UUID
        var mode: RouteLeg.Mode
        /// 이 구간이 끝나는 지점의 이름. 가족 카드의 "풍산역까지 12분" 이 여기서 나온다.
        var toName: String
        /// 이 구간이 끝나는 좌표. 대기 구간은 앞 구간과 같은 자리라 필요 없다.
        var to: CLLocationCoordinate2D?
        /// 이 구간에 걸리는 시간(분). **대중교통 앱이 말해 주는 값을 그대로 넣는다.**
        var minutes: Int

        /// 버스 노선번호(`999`). 버스 구간에만 뜻이 있고, 없어도 된다.
        ///
        /// **있으면 그 노선이 실제로 지나는 정류장을 따라 선을 그린다.** 없으면
        /// 자동차 경로로 그리는데, 버스는 정류장을 훑으며 돌기 때문에 길이 다르다.
        /// 999번(고양)에서 전원마을입구·동국로삼거리로 북쪽으로 올라갔다 내려오는
        /// 구간이 자동차 경로에는 없었다.
        var busNo: String?

        /// 이 구간에서 탈 수 있는 노선 전부. 편집기가 칩으로 받는다.
        ///
        /// `busNo` 는 그중 첫 번째다 — 선을 그리는 것과 옛 서버가 그 값을 쓴다.
        var busNos: [String] = []

        init(id: UUID = UUID(), mode: RouteLeg.Mode, toName: String = "",
             to: CLLocationCoordinate2D? = nil, minutes: Int = 5,
             busNo: String? = nil, busNos: [String] = []) {
            self.id = id
            self.mode = mode
            self.toName = toName
            self.to = to
            self.minutes = minutes
            self.busNo = busNo
            // 하나만 준 옛 호출도 그대로 돈다.
            self.busNos = busNos.isEmpty ? [busNo].compactMap { $0 } : busNos
        }

        // `CLLocationCoordinate2D` 는 Equatable 이 아니다. 좌표까지 봐야
        // 도착지를 다시 고른 것이 바뀜으로 잡힌다.
        static func == (a: Step, b: Step) -> Bool {
            a.id == b.id && a.mode == b.mode && a.toName == b.toName
                && a.minutes == b.minutes && a.busNo == b.busNo
                && a.busNos == b.busNos
                && a.to?.latitude == b.to?.latitude
                && a.to?.longitude == b.to?.longitude
        }
    }

    enum TraceError: LocalizedError {
        case noSteps
        case missingCoordinate(String)
        case directionsFailed(String, underlying: String)

        var errorDescription: String? {
            switch self {
            case .noSteps:
                return "구간이 없습니다."
            case .missingCoordinate(let name):
                return "\(name) 의 위치를 찾지 못했습니다."
            case .directionsFailed(let name, let underlying):
                return "\(name) 구간의 경로를 못 뽑았습니다. \(underlying)"
            }
        }
    }

    /// 출발지와 구간 목록으로 좌표열이 채워진 경로를 만든다.
    ///
    /// 구간은 이어진다 — N번째 구간의 출발은 N-1번째 구간의 도착이다. 사용자가
    /// 좌표를 두 번 넣지 않게 하려는 것이고, 실제로도 그렇게 이어져 있다.
    /// 버스 구간의 경유 정류장을 물어 준다. nil 이면 안 묻고 자동차 경로로 그린다.
    ///
    /// 서버만 공공데이터 키를 갖고 있어서 이 조회는 서버를 거친다. 실패하면
    /// 빈 배열이 오고, 그때는 지금까지처럼 자동차 경로다.
    /// **하차 좌표도 넘긴다.** 이름만으로는 길 양쪽 기둥을 못 가른다 —
    /// `위시티1.3단지` 가 5.0m 와 32.8m 로 둘 나왔고 둘 다 노선 순서가 승차보다
    /// 뒤여서 방향으로도 안 갈렸다(2026-08-27 실측). 사용자가 지도에서 찍은
    /// 점이 그것을 가른다.
    var busWaypoints: ((_ no: String, _ from: CLLocationCoordinate2D,
                        _ to: CLLocationCoordinate2D,
                        _ fromName: String, _ toName: String) async -> [CLLocationCoordinate2D])?

    /// 지하철 구간이 지나는 **역** 좌표를 물어 준다. nil 이면 두 역 직선으로 그린다.
    ///
    /// 실제 선로는 직선이 아니다. 서강대 → 풍산에서 직선이 실제 노선에서 **1,994m**
    /// 까지 벌어졌고(능곡역, 2026-08-26 실측), 이탈 문턱이 1,000m 라 정상 귀가가
    /// 이탈로 판정됐다 — 2026-08-25 실주행에서 그 뒤 39분을 이탈 상태로 돌았다.
    var subwayWaypoints: ((_ fromName: String, _ toName: String)
                          async -> [CLLocationCoordinate2D])?

    /// 그린 결과. **폴백을 함께 돌려준다.**
    ///
    /// 버스 노선 자료를 못 찾으면 자동차 경로로 그린다. 그건 "없는 길을 그리는 것"
    /// 보다 나은 선택이지만, **조용하면 안 된다** — 저장된 선의 모양이 실제 노선과
    /// 다르고, 그 사실은 저장한 사람만 알 수 있다(자료가 없는 지역은
    /// 서버 `BUS_SGG` 주석에 적혀 있다). 화면이 말할 수 있게 여기서 들고 나간다.
    struct Plotted {
        var legs: [RouteLeg]
        /// 실제 노선을 못 찾아 자동차 경로로 그린 버스 구간의 노선번호.
        var busFallbacks: [String] = []
        /// 노선을 못 찾아 두 역 직선으로 그린 지하철 구간의 도착역 이름.
        var subwayFallbacks: [String] = []
    }

    func plot(origin: CLLocationCoordinate2D, steps: [Step]) async throws -> Plotted {
        guard !steps.isEmpty else { throw TraceError.noSteps }

        var fallbacks: [String] = []
        var subwayFallbacks: [String] = []
        var legs: [RouteLeg] = []
        var cursor = origin
        var startsAt = 0
        // 버스 구간의 경유 정류장을 물을 때 "어디서 탔는지" 를 이름으로 넘겨야
        // 한다. 좌표 근처의 아무 정류장으로 기점을 잡으면 한 정류장 앞에서
        // 시작한다(서버 쪽 주석 참고).
        var previousName = ""

        for step in steps {
            let seconds = max(60, step.minutes * 60)
            let points: [[Double]]

            if step.mode == .wait {
                // 대기는 움직이지 않는다. 자리 하나면 서버가 이 구간을 알아본다.
                points = [[cursor.latitude, cursor.longitude]]
            } else {
                guard let destination = step.to else {
                    throw TraceError.missingCoordinate(step.toName.isEmpty ? step.mode.title : step.toName)
                }
                let traced = try await trace(step, from: cursor, to: destination,
                                             fromName: previousName)
                points = traced.points
                if traced.fellBack {
                    if step.mode == .subway {
                        subwayFallbacks.append(step.toName)
                    } else if let no = step.busNo?.trimmingCharacters(in: .whitespaces),
                              !no.isEmpty {
                        fallbacks.append(no)
                    }
                }
                cursor = destination
            }

            legs.append(RouteLeg(
                mode: step.mode,
                startsAt: startsAt,
                seconds: seconds,
                toName: step.toName.isEmpty ? nil : step.toName,
                points: points,
                busNo: step.mode == .bus ? step.busNos.first ?? step.busNo : nil,
                busNos: step.mode == .bus ? step.busNos : nil
            ))
            startsAt += seconds
            if step.mode.moves && !step.toName.isEmpty {
                previousName = step.toName
            }
        }

        return Plotted(legs: legs, busFallbacks: fallbacks, subwayFallbacks: subwayFallbacks)
    }

    /// 구간 하나의 좌표열. 버스에 노선번호가 있으면 그 노선을 따라 그린다.
    ///
    /// `fellBack` 은 **버스 노선을 따라 그리려 했는데 자료가 없어 자동차 경로로
    /// 대신 그렸다**는 뜻이다. 노선번호가 없는 버스나 다른 수단은 애초에 노선을
    /// 따라 그릴 대상이 아니므로 false 다.
    private func trace(
        _ step: Step,
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String
    ) async throws -> (points: [[Double]], fellBack: Bool) {

        if step.mode == .subway, let ask = subwayWaypoints {
            let stations = await ask(fromName, step.toName)
            if stations.count >= 2 {
                return (through(stations, from: from, to: to), false)
            }
            // 두 역이 함께 있는 노선을 못 찾았거나, 찾았는데 이어지지 않았다.
            // 예전처럼 직선으로 그리되 **조용히 하지 않는다.**
            HomecomingLog.push.warning(
                "지하철 \(step.toName, privacy: .public) 노선 자료가 없다 — 직선으로 그린다")
            return (straight(from: from, to: to), true)
        }

        guard step.mode == .bus, let no = step.busNo?.trimmingCharacters(in: .whitespaces),
              !no.isEmpty, let ask = busWaypoints
        else {
            return (try await line(step.mode, from: from, to: to, label: step.toName), false)
        }

        let stops = await ask(no, from, to, fromName, step.toName)
        guard !stops.isEmpty else {
            // 노선을 못 찾았다(서울 시내버스는 이 자료에 없고, 경기도 시군구 코드도
            // 확인된 것만 서버가 들고 있다). 예전처럼 자동차 경로로 그린다.
            //
            // **이 사실을 들고 나간다.** 예전에는 여기에 로그도 없어서, 저장된 선이
            // 실제 노선이 아닌 것을 아무도 알 수 없었다.
            HomecomingLog.push.warning(
                "버스 \(no, privacy: .public) 노선 자료가 없다 — 자동차 경로로 그린다")
            return (try await line(step.mode, from: from, to: to, label: step.toName), true)
        }

        // **정류장을 직접 잇는다. 사이를 도로 경로로 채우지 않는다.**
        //
        // 처음에는 정류장 사이마다 자동차 경로를 받아 이었다. 도로 모양까지
        // 맞으니 더 나을 것 같았는데, 화면에 **갈고리가 생겼다**. 연속한 두
        // 정류장이 길 양쪽에 있으면 자동차는 유턴해서 가야 하고, 그 유턴이 선에
        // 남는다(2026-08-20 사단앞·풍동빌라단지에서 보였다). 버스는 유턴하지
        // 않는다 — 있지도 않은 움직임을 그린 것이다.
        //
        // 정류장 간격이 300~500m 라 그 사이는 거의 직선이다. 직선으로 이으면
        // 살짝 각지지만 **없는 길을 그리지는 않는다.** 지하철 구간과 같은 판단이다.
        var line: [[Double]] = []
        var cursor = from
        for stop in stops + [to] {
            let part = straight(from: cursor, to: stop)
            // 맞닿은 점이 두 번 들어가지 않게 한다.
            line += (line.isEmpty ? part : Array(part.dropFirst()))
            cursor = stop
        }
        HomecomingLog.push.notice(
            "버스 \(no, privacy: .public) 구간을 실제 노선으로 그렸다 · 경유 \(stops.count)곳 · 점 \(line.count)개")
        return (line, false)
    }

    // MARK: - 구간 하나

    private func line(
        _ mode: RouteLeg.Mode,
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        label: String
    ) async throws -> [[Double]] {

        // 지하철은 도로 경로를 물어볼 이유가 없다. 물어보면 자동차 길이 나온다.
        if mode == .subway {
            return straight(from: from, to: to)
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        // 버스는 자동차로 대신한다. `.transit` 은 폴리라인을 주지 않는다.
        request.transportType = (mode == .walk) ? .walking : .automobile

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else {
                // 경로를 못 찾아도 구간을 버리지 않는다. 직선이라도 있으면 서버가
                // 구간을 판정할 수 있다. 비어 있으면 그 구간이 통째로 사라진다.
                return straight(from: from, to: to)
            }
            return ending(coordinates(of: route.polyline), at: to)
        } catch {
            // 실패 이유는 대개 일시적이다(요청 제한). 직선으로 대신한다 —
            // 도착예정은 실측 시간에서 나오니 좌표의 정밀도는 판정에만 영향이 있다.
            HomecomingLog.push.notice(
                "구간 좌표를 못 받아 직선으로 대신함: \(label, privacy: .public) · \(error.localizedDescription, privacy: .public)"
            )
            return straight(from: from, to: to)
        }
    }

    /// 좌표열이 **요청한 도착점에서 끝나게** 한다.
    ///
    /// MapKit 은 걸어갈 수 있는 가장 가까운 자리까지만 그려 준다. 아파트 단지
    /// 안쪽처럼 보행로 자료가 없는 곳이면 100m 밖에서 끊긴다. 그대로 두면
    /// 두 가지가 어긋난다 —
    ///   가족 지도의 선이 집 마커에 닿지 않고 그 앞에서 멈춘다(실제로 그랬다)
    ///   구간과 구간 사이에 틈이 생겨 다음 구간이 다른 자리에서 시작한다
    ///
    /// 마지막 점이 도착점과 멀면 도착점을 덧붙인다. 건물을 가로지르는 짧은
    /// 선이 생기지만, **가려는 곳에서 끝나는 것**이 더 정직하다.
    private func ending(_ points: [[Double]], at destination: CLLocationCoordinate2D) -> [[Double]] {
        let target = [destination.latitude, destination.longitude]
        guard let last = points.last, last.count == 2 else { return points + [target] }
        let gap = CLLocation(latitude: last[0], longitude: last[1])
            .distance(from: CLLocation(latitude: destination.latitude,
                                       longitude: destination.longitude))
        return gap <= 30 ? points : points + [target]
    }

    private func coordinates(of line: MKPolyline) -> [[Double]] {
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: line.pointCount)
        line.getCoordinates(&coords, range: NSRange(location: 0, length: line.pointCount))
        // 소수점 여섯 자리면 10cm 다. 그 이상은 저장할 이유가 없다.
        return coords.map {
            [($0.latitude * 1e6).rounded() / 1e6, ($0.longitude * 1e6).rounded() / 1e6]
        }
    }

    /// 역 좌표들을 순서대로 잇고 사이를 보간한다.
    ///
    /// **양 끝은 요청받은 좌표로 맞춘다.** 자료의 역 좌표와 경로가 든 좌표가 몇십
    /// 미터 다를 수 있는데, 그대로 두면 구간 사이에 틈이 생겨 다음 구간이 다른
    /// 자리에서 시작한다 — `ending(_:at:)` 이 막는 것과 같은 문제다.
    private func through(
        _ stations: [CLLocationCoordinate2D],
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> [[Double]] {
        var nodes = stations
        nodes[0] = from
        nodes[nodes.count - 1] = to
        var points: [[Double]] = []
        for index in 0..<(nodes.count - 1) {
            let piece = straight(from: nodes[index], to: nodes[index + 1])
            points += (index == 0) ? piece : Array(piece.dropFirst())
        }
        return points
    }

    private func straight(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> [[Double]] {
        let span = CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
        let steps = max(Int(span / subwaySpacing), 1)
        return (0...steps).map { index in
            let ratio = Double(index) / Double(steps)
            return [
                ((from.latitude + (to.latitude - from.latitude) * ratio) * 1e6).rounded() / 1e6,
                ((from.longitude + (to.longitude - from.longitude) * ratio) * 1e6).rounded() / 1e6,
            ]
        }
    }
}
