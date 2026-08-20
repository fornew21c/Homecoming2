// MapKit 으로 실제 도로 경로와 장소 좌표를 뽑는다.
//
//   route-dump route <출발lat> <출발lon> <도착lat> <도착lon> [automobile|walking]
//   route-dump geocode "회사"
//
// Tools/route-make.py 가 부른다. 애플이 대중교통 좌표열은 주지 않으므로
// 버스는 자동차 경로로 대체하고 철도는 역 좌표를 직선으로 잇는다.

import Foundation
import MapKit

let argv = CommandLine.arguments

func die(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func emit(_ object: Any) -> Never {
    let data = try! JSONSerialization.data(withJSONObject: object)
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}

// ------------------------------------------------------------------ 장소 검색

func geocode(_ query: String) {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    // 한국으로 한정한다. 같은 이름이 세계에 여럿 있다.
    request.region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.55, longitude: 127.0),
        span: MKCoordinateSpan(latitudeDelta: 4.0, longitudeDelta: 4.0)
    )

    MKLocalSearch(request: request).start { response, error in
        if let items = response?.mapItems, !items.isEmpty {
            let found = items.prefix(3).map { item -> [String: Any] in
                let c = item.placemark.coordinate
                return [
                    "name": item.name ?? query,
                    "lat": (c.latitude * 1e6).rounded() / 1e6,
                    "lon": (c.longitude * 1e6).rounded() / 1e6,
                    "address": item.placemark.title ?? "",
                ]
            }
            emit(["query": query, "results": Array(found)])
        }
        // MKLocalSearch 는 CLI 에서 잘 스로틀링된다(MKErrorDomain 4).
        // CLGeocoder 는 다른 경로를 쓰므로 한 번 더 시도할 값이 있다.
        let reason = error?.localizedDescription ?? "결과 없음"
        CLGeocoder().geocodeAddressString(query) { marks, geoError in
            guard let marks, !marks.isEmpty else {
                die("장소를 못 찾았다: \(reason) / \(geoError?.localizedDescription ?? "결과 없음")")
            }
            let found = marks.prefix(3).compactMap { mark -> [String: Any]? in
                guard let c = mark.location?.coordinate else { return nil }
                return [
                    "name": mark.name ?? query,
                    "lat": (c.latitude * 1e6).rounded() / 1e6,
                    "lon": (c.longitude * 1e6).rounded() / 1e6,
                    "address": [mark.locality, mark.thoroughfare].compactMap { $0 }.joined(separator: " "),
                ]
            }
            emit(["query": query, "results": found])
        }
    }
    RunLoop.main.run()
}

// ------------------------------------------------------------------ 도로 경로

func route(_ from: CLLocationCoordinate2D, _ to: CLLocationCoordinate2D, _ mode: String) {
    let request = MKDirections.Request()
    request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
    request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
    request.transportType = (mode == "walking") ? .walking : .automobile

    MKDirections(request: request).calculate { response, error in
        if let error { die("경로를 못 뽑았다: \(error.localizedDescription)") }
        guard let found = response?.routes.first else { die("경로 없음") }

        let line = found.polyline
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: line.pointCount)
        line.getCoordinates(&coords, range: NSRange(location: 0, length: line.pointCount))
        let points = coords.map {
            [($0.latitude * 1e6).rounded() / 1e6, ($0.longitude * 1e6).rounded() / 1e6]
        }
        emit([
            "distance": Int(found.distance),
            "seconds": Int(found.expectedTravelTime),
            "points": points,
        ])
    }
    RunLoop.main.run()
}

// ------------------------------------------------------------------ 진입

guard argv.count >= 2 else { die("사용법: route-dump route <4좌표> [mode] | geocode <장소>") }

switch argv[1] {
case "geocode":
    guard argv.count >= 3 else { die("장소 이름이 필요하다") }
    geocode(argv[2])

case "route":
    guard argv.count >= 6,
          let a = Double(argv[2]), let b = Double(argv[3]),
          let c = Double(argv[4]), let d = Double(argv[5])
    else { die("좌표 4개가 필요하다") }
    route(.init(latitude: a, longitude: b), .init(latitude: c, longitude: d),
          argv.count > 6 ? argv[6] : "automobile")

default:
    die("모르는 명령: \(argv[1])")
}
