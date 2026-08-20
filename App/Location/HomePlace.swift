import CoreLocation
import Foundation

/// 도착지. 사용자가 한 번 등록해 두면 계속 쓴다.
struct HomePlace: Codable, Hashable, Sendable {

    var name: String
    var latitude: CLLocationDegrees
    var longitude: CLLocationDegrees

    /// 이 반경 안에 들어오면 도착으로 본다(m).
    /// 도시 환경의 GPS 오차와 아파트 단지 크기를 감안한 값.
    var arrivalRadius: CLLocationDistance = 120

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    init(name: String = "집", coordinate: CLLocationCoordinate2D, arrivalRadius: CLLocationDistance = 120) {
        self.name = name
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.arrivalRadius = arrivalRadius
    }
}

// MARK: - 저장

extension HomePlace {

    private static let storageKey = "homecoming.homePlace"

    static func load(from defaults: UserDefaults = .standard) -> HomePlace? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(HomePlace.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}
