// 지도가 경로를 **어디서 자르는지** 앱과 같은 코드로 재 본다.
//
//   swiftc -O Tools/trail-cut.swift App/Watching/RouteTrail.swift -o /tmp/trail-cut
//   echo '{"segments": [[[37.5,126.9],[37.6,126.9]]], "cuts": [5000]}' | /tmp/trail-cut
//
// **`App/Watching/RouteTrail.swift` 를 그대로 컴파일한다.** 계산을 이 파일에 옮겨
// 적으면 시험이 자기 사본을 시험한다 — 앱이 쓰는 원본이어야 의미가 있다.
//
// `Tools/verify-progress-sync.py` 가 부른다. 그쪽이 서버가 낸 진행도를 `cuts` 로
// 넣고, 여기서 나온 `passed`(지나온 것으로 그리는 길이)와 견줘 차이를 표로 찍는다.
// 둘이 같아야 카드의 노선도 점과 지도의 색 분리가 같은 자리를 말한다.

import CoreLocation
import Foundation

struct Input: Decodable {
    /// 구간별 좌표열. `[[[lat, lon], ...], ...]`. 서버 `/session/{id}/route` 의
    /// `segments[].points` 를 그대로 넣는다.
    let segments: [[[Double]]]

    /// 자를 자리(m). 서버가 준 `travelledMeters` 를 넣는다.
    let cuts: [Double]

    /// 귀가자의 자리 `[[lat, lon], ...]`. **옛 계산을 재는 데 쓴다** —
    /// 진행도를 모르던 지도는 여기서 가장 가까운 점까지의 누적으로 잘랐다.
    let spots: [[Double]]?
}

@main
struct TrailCut {

    static func main() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let input = try JSONDecoder().decode(Input.self, from: data)

        let trail = RouteTrail(segments: input.segments.map { segment in
            segment.compactMap {
                $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil
            }
        })

        var cuts: [[String: Any]] = []
        for cut in input.cuts {
            let parts = trail.cut(at: cut)
            // 지나온 것으로 그리는 길이의 합. 지도가 흐리게 칠하는 길이 그것이다.
            let passed = parts.reduce(0.0) { $0 + RouteTrail.length(of: $1.passed) }
            // 자른 자리의 좌표. 지나온 토막의 마지막 점이다.
            let point = parts.last(where: { !$0.passed.isEmpty })?.passed.last
            // **자른 자리를 부르는 쪽이 되잴 수 있게 남긴다.** 지나온 길이만
            // 돌려주면 그 값은 `RouteTrail` 이 자기 자로 잰 것이라, 요청한 거리와
            // 같은 것이 당연하다 — 그걸로는 아무것도 확인되지 않는다. 어느 구간의
            // 몇 번째 점까지 지나왔는지와 자른 좌표를 주면, 부르는 쪽이 **서버의
            // 자(haversine)로** 같은 자리를 다시 재서 두 자를 견줄 수 있다.
            let segment = parts.lastIndex(where: { !$0.passed.isEmpty }) ?? 0
            cuts.append([
                "at": cut,
                "passed": passed,
                "segment": segment,
                "passedCount": parts[segment].passed.count,
                "lat": point?.latitude ?? 0,
                "lon": point?.longitude ?? 0,
                // **지도에 넘기는 선을 그대로 내보낸다.** 부르는 쪽이 잃은 거리가
                // 없는지(지나온 + 남은 = 구간 길이), 두 토막이 자른 점을 나눠
                // 갖는지(안 그러면 선에 틈이 보인다), 점 하나짜리 토막이 그려질
                // 자리에 없는지 검사한다. 자르는 자리만 맞고 선이 틀리면 화면은
                // 틀린 그림을 그린다.
                "parts": parts.map { part -> [String: Any] in
                    [
                        "p": part.passed.count,
                        "r": part.remaining.count,
                        "pl": RouteTrail.length(of: part.passed),
                        "rl": RouteTrail.length(of: part.remaining),
                        "shared": (part.passed.last.map { last in
                            part.remaining.first.map {
                                $0.latitude == last.latitude && $0.longitude == last.longitude
                            } ?? true
                        } ?? true),
                    ]
                },
                // 그려질 토막의 개수. 진행 지점이 구간 안이면 그 구간만 둘로 갈린다.
                "pieces": parts.reduce(0) {
                    $0 + ($1.passed.count >= 2 ? 1 : 0) + ($1.remaining.count >= 2 ? 1 : 0)
                },
            ])
        }

        var spots: [[String: Any]] = []
        for spot in input.spots ?? [] where spot.count == 2 {
            let here = CLLocationCoordinate2D(latitude: spot[0], longitude: spot[1])
            spots.append([
                "lat": spot[0], "lon": spot[1],
                "travelled": trail.travelled(nearestTo: here),
            ])
        }

        let out = try JSONSerialization.data(
            withJSONObject: ["total": trail.length, "cuts": cuts, "spots": spots])
        print(String(data: out, encoding: .utf8)!)
    }
}
