import CoreLocation
import Foundation
import MapKit

/// 기기 안에서 끝나는 추정. API 키도 서버도 필요 없다.
///
/// MapKit 은 대중교통 경로를 내주지 않으므로 도보/자동차만 쓴다.
/// 대중교통 구간에서는 실제보다 낙관적으로 나올 수 있어, 어디까지나 폴백이다.
struct MapKitETAProvider: ETAProviding {

    /// 이 거리 이하는 걸어간다고 본다.
    var walkingThresholdMeters: CLLocationDistance = 1_200

    func estimate(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async throws -> ETAEstimate {

        let straight = origin.straightLineDistance(to: destination)
        let walking = straight <= walkingThresholdMeters

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = walking ? .walking : .automobile

        let response = try await MKDirections(request: request).calculateETA()

        guard response.expectedTravelTime > 0 else { throw ETAError.noRoute }

        return ETAEstimate(
            expectedArrival: Date().addingTimeInterval(response.expectedTravelTime),
            routeMeters: Int(response.distance.rounded()),
            transport: walking ? .walk : .car,
            detail: nil,
            source: .mapKit
        )
    }
}

/// 네트워크가 아예 죽었을 때의 마지막 보루.
///
/// 직선 거리에 우회 계수를 곱하고 이동 수단별 평속으로 나눈다.
/// 정확하지는 않지만, 아무 값도 못 주는 것보다는 낫다 —
/// Live Activity 는 한 번 뜨면 도착까지 화면에 남아 있어야 한다.
struct DeadReckoningETAProvider: ETAProviding {

    /// 직선 거리를 실제 경로 거리로 부풀리는 계수. 도심 격자 도로 기준.
    var detourFactor: Double = 1.3

    func estimate(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async throws -> ETAEstimate {

        let route = origin.straightLineDistance(to: destination) * detourFactor

        // m/분. 도보 70, 시내 자동차 400, 지하철 포함 대중교통 450.
        let (speed, transport): (Double, HomecomingAttributes.Transport) =
            route <= 1_200 ? (70, .walk)
            : route <= 6_000 ? (400, .car)
            : (450, .subway)

        let minutes = max(1, route / speed)

        return ETAEstimate(
            expectedArrival: Date().addingTimeInterval(minutes * 60),
            routeMeters: Int(route.rounded()),
            transport: transport,
            detail: nil,
            source: .deadReckoning
        )
    }
}

/// 앞의 것부터 차례로 시도하고, 실패하면 다음으로 넘어간다.
///
/// 대중교통 추정 → MapKit → 기기 내 추측 순으로 엮어 쓴다.
struct FallbackETAProvider: ETAProviding {

    let providers: [ETAProviding]

    init(_ providers: [ETAProviding]) {
        self.providers = providers
    }

    func estimate(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async throws -> ETAEstimate {

        var lastError: Error = ETAError.noRoute

        for provider in providers {
            do {
                return try await provider.estimate(from: origin, to: destination)
            } catch {
                lastError = error
                // 취소는 폴백 대상이 아니다. 상위가 그만두라고 한 것이므로 즉시 전파한다.
                if error is CancellationError { throw error }
            }
        }

        throw lastError
    }
}
