import CoreLocation
import Foundation

/// 대중교통 도착 추정. 실제 계산은 우리 서버가 한다.
///
/// TMAP·카카오·서울시 실시간 도착정보를 앱에서 직접 부르지 않는 이유:
/// - 벤더 API 키를 앱 번들에 넣으면 그냥 유출된다. 키는 서버에만 둔다.
/// - 벤더를 갈아 끼울 때 앱을 새로 배포하지 않아도 된다.
/// - 같은 추정 로직을 Live Activity 푸시를 쏘는 서버와 공유할 수 있다.
///   앱이 잠들어 있어도 서버가 같은 값으로 갱신을 밀어 준다.
///
/// 요청·응답 형식 (docs/API-SPEC.md):
/// ```
/// POST {baseURL}/eta
/// { "origin": {"lat": 37.5, "lon": 127.0}, "destination": {"lat": 37.6, "lon": 127.1} }
///
/// 200 {
///   "expectedArrival": "2026-08-12T19:24:00Z",   // ISO8601
///   "routeMeters": 11340,
///   "mode": "subway",                             // subway | bus | car | walk
///   "detail": "2호선 · 3정거장 남음"                 // optional
/// }
/// ```
struct TransitETAProvider: ETAProviding {

    let baseURL: URL
    var session: URLSession = .shared

    /// 이 시간을 넘기면 폴백으로 넘어간다.
    /// 사용자는 다이나믹 아일랜드가 멎어 있는 걸 더 싫어한다 — 늦은 정답보다 빠른 근사가 낫다.
    var timeout: TimeInterval = 6

    func estimate(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async throws -> ETAEstimate {

        var request = URLRequest(url: baseURL.appendingPathComponent("eta"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Payload(origin: .init(origin), destination: .init(destination))
        )

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else { throw ETAError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else { throw ETAError.badResponse(http.statusCode) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let body = try? decoder.decode(Response.self, from: data) else { throw ETAError.decoding }

        return ETAEstimate(
            expectedArrival: body.expectedArrival,
            routeMeters: body.routeMeters,
            transport: HomecomingAttributes.Transport(rawValue: body.mode) ?? .subway,
            detail: body.detail,
            source: .transit
        )
    }

    // MARK: - 전송 형태

    private struct Payload: Encodable {
        let origin: Point
        let destination: Point

        struct Point: Encodable {
            let lat: Double
            let lon: Double

            init(_ coordinate: CLLocationCoordinate2D) {
                lat = coordinate.latitude
                lon = coordinate.longitude
            }
        }
    }

    private struct Response: Decodable {
        let expectedArrival: Date
        let routeMeters: Int
        let mode: String
        let detail: String?
    }
}
