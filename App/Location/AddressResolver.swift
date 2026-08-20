import CoreLocation
import Foundation
import Observation

/// 좌표를 사람이 읽는 주소로 바꾼다.
///
/// `CLGeocoder` 는 요청을 세게 제한한다(짧은 시간에 여러 번 부르면 그냥 실패한다).
/// 그래서 일정 거리 이상 움직였을 때만 다시 묻고, 결과는 다음 번까지 들고 있는다.
@MainActor
@Observable
final class AddressResolver {

    private(set) var address: String?
    private(set) var isResolving = false

    /// 이만큼 움직이기 전에는 다시 묻지 않는다.
    var minimumMove: CLLocationDistance = 120

    private let geocoder = CLGeocoder()
    private var anchor: CLLocation?
    private var task: Task<Void, Never>?

    func resolve(_ location: CLLocation) {
        if let anchor, location.distance(from: anchor) < minimumMove, address != nil { return }
        guard task == nil else { return }

        anchor = location
        isResolving = true

        task = Task { [weak self] in
            defer {
                self?.task = nil
                self?.isResolving = false
            }
            guard let placemark = try? await self?.geocoder.reverseGeocodeLocation(location).first else {
                // 실패는 조용히 넘긴다. 주소는 있으면 좋은 정보지 없으면 안 되는 정보가 아니다.
                return
            }
            guard !Task.isCancelled else { return }
            self?.address = Self.format(placemark)
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        anchor = nil
        address = nil
        isResolving = false
    }

    /// 한국 주소는 시/구 전체를 붙이면 길기만 하다. 동·도로명·건물번호면 충분히 알아본다.
    static func format(_ placemark: CLPlacemark) -> String {
        let detail = [placemark.subLocality, placemark.thoroughfare, placemark.subThoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")

        if !detail.isEmpty { return detail }
        return placemark.name ?? placemark.locality ?? ""
    }
}
