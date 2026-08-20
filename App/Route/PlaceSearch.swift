import CoreLocation
import Foundation
import MapKit
import Observation

/// 이름으로 장소를 찾는다. "서강대역" → 좌표.
///
/// 경로를 폰에서 만들려면 이게 있어야 한다. 사용자는 좌표를 모른다 — 역 이름과
/// 정류장 이름만 안다. 그 사이를 메우는 게 이 타입이다.
///
/// `CLGeocoder` 가 아니라 `MKLocalSearch` 를 쓴다. 지오코더는 주소를 푸는 도구라
/// "서강대역" 같은 시설 이름에 약하다. 맥에서 명령줄로 시험했을 때 한국 역 이름이
/// 통째로 실패했다(`kCLErrorDomain 8`). 검색은 시설 이름으로 찾는 도구다.
@MainActor
@Observable
final class PlaceSearch {

    struct Hit: Identifiable, Equatable {
        let id = UUID()
        let name: String
        /// 어느 동네인지. 같은 이름의 정류장이 여러 개라 이게 없으면 고를 수 없다.
        let context: String?
        let coordinate: CLLocationCoordinate2D

        static func == (a: Hit, b: Hit) -> Bool { a.id == b.id }
    }

    private(set) var hits: [Hit] = []
    private(set) var isSearching = false
    private(set) var lastError: String?

    /// 검색을 좁힐 기준점. 현재 위치나 집을 넣는다.
    ///
    /// 없으면 "풍산역" 이 전국에서 나온다. 귀가 경로는 늘 자기 동네 안이라
    /// 기준점을 주는 것이 맞다.
    var near: CLLocationCoordinate2D?

    private var inFlight: Task<Void, Never>?

    func search(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        inFlight?.cancel()

        // 옛 결과를 즉시 지운다. 깜박임을 줄이려고 남겨 두면 **앞 검색의 결과를
        // 새 검색의 결과로 착각해서 찍는다** — 그러면 경로에 엉뚱한 좌표가 박히고,
        // 서버는 그 자리를 지나갔는지로 구간을 판정하니 조용히 어긋난다.
        // 지금 보이는 목록은 지금 쓴 글자의 것이어야 한다.
        hits = []
        lastError = nil

        guard query.count >= 2 else { return }

        inFlight = Task { [weak self] in
            // 한 글자 칠 때마다 요청하면 애플이 막는다(MKErrorDomain 4, 요청 제한).
            // 실제로 그걸로 막혔다. 손이 멈춘 다음에 보낸다.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.run(query)
        }
    }

    private func run(_ query: String) async {
        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let near {
            // 40km — 수도권 통근 범위. 더 넓히면 다른 도시의 같은 이름이 섞인다.
            request.region = MKCoordinateRegion(center: near, latitudinalMeters: 40_000, longitudinalMeters: 40_000)
        }

        // 요청 제한(`MKError.loadingThrottled`)은 실기기에서도 걸린다. 여섯 곳을
        // 이어서 찾으면 그중 하나가 빈손으로 돌아왔다. 사용자에게는 "못 찾음" 으로
        // 보이는데 실제로는 잠깐 기다리면 되는 것이라, 한 번 쉬고 다시 묻는다.
        for attempt in 0..<2 {
            do {
                let response = try await MKLocalSearch(request: request).start()
                guard !Task.isCancelled else { return }
                hits = response.mapItems.prefix(8).map { item in
                    Hit(
                        name: item.name ?? query,
                        context: Self.context(of: item),
                        coordinate: item.placemark.coordinate
                    )
                }
                lastError = hits.isEmpty ? "\"\(query)\" 을(를) 찾지 못했습니다." : nil
                return
            } catch {
                guard !Task.isCancelled else { return }
                let throttled = (error as? MKError)?.code == .loadingThrottled
                if throttled, attempt == 0 {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                hits = []
                lastError = throttled
                    ? "지도 검색이 잠시 제한되었습니다. 몇 초 뒤 다시 시도하세요."
                    : error.localizedDescription
                return
            }
        }
    }

    /// "마포구 신수동" 처럼 어디인지 알려 주는 한 줄.
    private static func context(of item: MKMapItem) -> String? {
        let mark = item.placemark
        let parts = [mark.locality, mark.subLocality, mark.thoroughfare].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
