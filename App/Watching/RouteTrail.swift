import CoreLocation

/// 경로를 **지나온 거리**에서 자르는 계산.
///
/// 지도의 지나온/남은 색 분리가 이것을 쓴다. 자를 자리는 서버가 준 진행도
/// (`ContentState.travelledMeters`)이고, 카드의 노선도 점이 쓰는 값과 같다 —
/// 두 화면이 "얼마나 왔나" 를 각자 계산하던 것을 한 벌로 합친 자리다.
///
/// **뷰에서 떼어 놓은 이유는 두 가지다.**
/// 1. 그리는 일과 무관하다. 좌표열과 거리 하나가 입력의 전부다.
/// 2. **재 볼 수 있어야 한다.** 이 파일은 CoreLocation 만 쓰므로 `swiftc` 로 따로
///    컴파일해서 서버가 보낸 진행도와 맞는지 잴 수 있다. 앱이 컴파일하는 바로 그
///    원본으로 재는 것이 중요하다 — 계산을 시험 쪽에 옮겨 적으면 시험은 자기
///    사본을 시험한다.
struct RouteTrail {

    /// 구간별 좌표열. 순서가 이동 순서다.
    ///
    /// **이어붙인 하나가 아니라 구간별로 받는다. 축이 다르기 때문이다.**
    ///
    /// 구간 경계에는 이음이 있다 — 앞 구간의 끝점과 뒤 구간의 시작점이 같은 자리가
    /// 아니다(버스가 정류장에 세워 준 자리와 걸어 나가기 시작하는 자리가 다르다).
    /// 이어붙인 좌표열로 누적을 재면 그 이음이 거리에 섞여 든다. 실측
    /// (`Tools/routes/commute-sample.json`, 28.4km): 이음이 세 곳에 31.8m·52.1m·14.0m,
    /// 합 97.9m.
    ///
    /// 서버의 진행도는 `route_length()` 로 재고 그쪽은 **구간 안만** 잰다. 그래서
    /// 구간별로 누적해야 같은 자가 된다 — 같은 경로에서 차이가 3m 로 떨어진다
    /// (좌표를 소수 5자리로 보내는 데서 오는 값이다).
    ///
    /// `CLLocation.distance` 와 서버 `haversine()` 의 차이는 같은 경로에서 6.8m 로
    /// 쟀다. 자를 바꿀 이유가 되지 않는다.
    let segments: [[CLLocationCoordinate2D]]

    /// 잘린 구간 하나. 두 토막이 자른 점을 **함께** 갖는다 — 안 나눠 가지면
    /// 선에 틈이 보인다. 진행 지점 앞이나 뒤의 구간은 한쪽이 빈다.
    struct Part {
        var passed: [CLLocationCoordinate2D]
        var remaining: [CLLocationCoordinate2D]
    }

    /// 누적 거리 `meters` 자리에서 자른다. 결과는 `segments` 와 같은 길이·순서다.
    func cut(at meters: Double) -> [Part] {
        var parts: [Part] = []
        var walked = 0.0
        for points in segments {
            let length = Self.length(of: points)
            if walked + length <= meters {
                parts.append(Part(passed: points, remaining: []))
            } else if walked >= meters {
                parts.append(Part(passed: [], remaining: points))
            } else {
                parts.append(Self.split(points, at: meters - walked))
            }
            walked += length
        }
        return parts
    }

    /// 경로 전체 길이(m). 구간 안만 잰 합이다.
    var length: Double { segments.reduce(0) { $0 + Self.length(of: $1) } }

    /// 좌표열에서 이 자리에 가장 가까운 점까지의 누적 거리(m).
    ///
    /// **폴백이다.** 서버가 진행도를 안 보낼 때(이 필드를 모르는 옛 서버) 쓴다.
    /// 2026-08-20 이전에는 지도가 늘 이렇게 잘랐고, 그래서 카드와 갈라졌다 —
    /// 정상 이동에서는 평균 36m 로 맞지만 GPS 가 역행하면 되돌아가고(실측 7,404m
    /// 차이) 경로를 벗어나면 엉뚱한 자리를 고른다(4,349m).
    func travelled(nearestTo here: CLLocationCoordinate2D) -> Double {
        let spot = CLLocation(latitude: here.latitude, longitude: here.longitude)
        var walked = 0.0
        var nearest = 0.0
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        for points in segments {
            for (index, point) in points.enumerated() {
                if index > 0 { walked += Self.distance(points[index - 1], point) }
                let distance = spot.distance(
                    from: CLLocation(latitude: point.latitude, longitude: point.longitude))
                if distance < bestDistance {
                    bestDistance = distance
                    nearest = walked
                }
            }
        }
        return nearest
    }

    // MARK: - 자

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    static func length(of points: [CLLocationCoordinate2D]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    /// 좌표열 하나를 누적 거리 `meters` 자리에서 자른다.
    ///
    /// **꼭짓점에 붙이지 않고 그 자리에 점을 만든다.** 같은 경로에서 점 사이가
    /// 중앙값 95.7m, 최대 828.1m 다 — 가까운 꼭짓점으로 밀면 색 분리가 그만큼
    /// 어긋난다. 서버 진행도와 0m 로 맞추려고 통일했는데 그리는 자리에서 100m 를
    /// 잃으면 통일한 값이 없다.
    static func split(_ points: [CLLocationCoordinate2D], at meters: Double) -> Part {
        var walked = 0.0
        for index in points.indices.dropLast() {
            let a = points[index]
            let b = points[index + 1]
            let step = distance(a, b)
            if walked + step >= meters {
                // 남은 몫을 이 선분 안에서 비례로 나눈다. 100m 남짓 안에서는
                // 위도·경도를 그냥 섞어도 눈에 보이는 오차가 없다.
                let fraction = step > 0 ? (meters - walked) / step : 0
                let at = CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                    longitude: a.longitude + (b.longitude - a.longitude) * fraction)
                return Part(passed: Array(points[...index]) + [at],
                            remaining: [at] + Array(points[(index + 1)...]))
            }
            walked += step
        }
        // 자를 자리가 좌표열 끝을 넘었다. 전부 지나온 것이다.
        return Part(passed: points, remaining: [])
    }
}
