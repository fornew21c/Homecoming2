import CoreLocation
import Foundation

/// 한 번의 도착 예정 추정 결과.
struct ETAEstimate: Sendable, Equatable {

    /// 도착 예정 시각. Live Activity 는 남은 분이 아니라 이 시각을 들고 다닌다.
    var expectedArrival: Date

    /// 실제 경로 거리(m). 직선 거리가 아니다.
    var routeMeters: Int

    var transport: HomecomingAttributes.Transport

    /// "2호선 · 3정거장 남음" 같은 보조 문구. 대중교통 추정에서만 채워진다.
    var detail: String?

    /// 어느 경로로 얻은 값인지. 로그와 폴백 판단에 쓴다.
    var source: Source

    /// 저장된 경로로 도는 귀가면 그 노선도. 다른 출처(MapKit 등)면 nil 이다.
    var routeShape: HomecomingAttributes.RouteShape? = nil

    /// 지금부터 도착까지의 분. 로그와 화면 표시에 쓴다.
    var remainingMinutesFromNow: Int {
        max(0, Int((expectedArrival.timeIntervalSinceNow / 60).rounded()))
    }

    enum Source: String, Sendable {
        /// 저장된 경로의 실측 소요시간. **추정이 아니라 아는 값이다.**
        case savedRoute
        /// 서버 대중교통 프록시.
        case transit
        /// 기기 내 MapKit(도보/자동차).
        case mapKit
        /// 아무 데도 못 붙었을 때의 기기 내 추측.
        case deadReckoning
        /// **귀가자가 직접 적은 시간.** 경로 없이 시작한 귀가에서 쓴다.
        ///
        /// 저장된 경로가 `savedRoute` 인 것과 같은 성격이다 — 추정이 아니라 아는
        /// 값이다. 회식 자리에서 귀가하는 사람은 저장된 경로가 없지만 "한 시간쯤"
        /// 은 안다. 그 값을 그대로 쓴다. MapKit 자동차 경로로 짐작하면 82분 길이
        /// 19분으로 뜨는데, 그건 아무것도 안 알리는 것보다 나쁘다.
        case traveler
    }
}

/// 출발 좌표에서 도착 좌표까지의 ETA 를 추정하는 무언가.
protocol ETAProviding: Sendable {
    func estimate(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async throws -> ETAEstimate
}

enum ETAError: LocalizedError {
    case noRoute
    case badResponse(Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .noRoute:            return "경로를 찾지 못했습니다."
        case .badResponse(let c): return "도착정보 서버 응답 오류 (\(c))"
        case .decoding:           return "도착정보 응답을 해석하지 못했습니다."
        }
    }
}

// MARK: - 좌표 보조

extension CLLocationCoordinate2D {
    var asLocation: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    func straightLineDistance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        asLocation.distance(from: other.asLocation)
    }
}
