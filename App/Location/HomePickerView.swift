import CoreLocation
import MapKit
import SwiftUI

/// 지도에서 집을 임의로 지정한다.
///
/// 핀을 탭해서 찍는 대신 **지도를 움직여 중앙에 맞추는** 방식이다.
/// 한 손으로 쓸 수 있고, 손가락에 가려지지 않으며, 정밀한 탭을 요구하지 않는다.
struct HomePickerView: View {

    let initial: HomePlace?
    let currentLocation: CLLocation?
    let onSave: (HomePlace) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var camera: MapCameraPosition
    @State private var center: CLLocationCoordinate2D
    @State private var radius: CLLocationDistance
    @State private var name: String

    /// 사용자가 이름을 직접 고쳤으면 역지오코딩이 덮어쓰지 않는다.
    @State private var nameEdited = false

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var geocodeTask: Task<Void, Never>?
    @State private var searchError: String?

    /// 지오펜스 반경 하한.
    ///
    /// iOS 지역 감시는 100m 아래에서 신뢰도가 급격히 떨어진다.
    /// 더 좁게 열어 주면 "도착 알림이 안 와요" 로 돌아온다.
    private static let minRadius: CLLocationDistance = 100
    private static let maxRadius: CLLocationDistance = 500

    private let tint = Color(red: 0.36, green: 0.62, blue: 1.0)

    init(
        initial: HomePlace?,
        currentLocation: CLLocation?,
        onSave: @escaping (HomePlace) -> Void
    ) {
        self.initial = initial
        self.currentLocation = currentLocation
        self.onSave = onSave

        let start = initial?.coordinate
            ?? currentLocation?.coordinate
            ?? CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)   // 서울시청

        _center = State(initialValue: start)
        _radius = State(initialValue: initial?.arrivalRadius ?? 150)
        _name = State(initialValue: initial?.name ?? "집")
        _nameEdited = State(initialValue: initial != nil)
        _camera = State(initialValue: .region(
            MKCoordinateRegion(center: start, latitudinalMeters: 800, longitudinalMeters: 800)
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // 핀은 지도의 **확장된** 프레임 위에 얹어야 한다.
                // ZStack 에 따로 놓으면 세이프에어리어만큼 중심이 어긋나서,
                // 핀이 가리키는 곳과 반경 원의 중심이 서로 다른 지점이 된다.
                // ignoresSafeArea 는 오버레이 **바깥**에 걸어야 둘이 같은 프레임을 쓴다.
                // 안쪽에 걸면 지도만 확장돼 중심이 세이프에어리어의 절반만큼 어긋난다.
                map
                    .overlay { centerPin }
                    .ignoresSafeArea(edges: .bottom)
                searchLayer
                VStack { Spacer(); controls }
            }
            .navigationTitle("집 위치 지정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 지도

    private var map: some View {
        Map(position: $camera) {
            MapCircle(center: center, radius: radius)
                .foregroundStyle(tint.opacity(0.16))
                .stroke(tint.opacity(0.9), lineWidth: 2)
        }
        .mapStyle(.standard(elevation: .flat))
        .onMapCameraChange(frequency: .continuous) { context in
            center = context.region.center
        }
        .onMapCameraChange(frequency: .onEnd) { _ in
            scheduleReverseGeocode()
        }
    }

    /// 지도 위에 고정된 중앙 핀. 지도 콘텐츠가 아니라 오버레이라서 항상 화면 중앙에 있다.
    private var centerPin: some View {
        VStack(spacing: 0) {
            Image(systemName: "house.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint))
                .shadow(radius: 4, y: 2)
            Rectangle()
                .fill(tint)
                .frame(width: 2, height: 12)
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
        }
        // 핀 끝이 중앙을 가리키도록 위로 올린다.
        .offset(y: -26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    // MARK: - 검색

    private var searchLayer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("주소 · 건물명 검색", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { runSearch() }
                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if !results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(results.indices, id: \.self) { index in
                        Button {
                            choose(results[index])
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(results[index].name ?? "이름 없음")
                                    .font(.system(size: 14, weight: .medium))
                                Text(Self.addressLine(results[index]))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)

                        if index != results.indices.last {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 6)
            }

            if let searchError {
                Text(searchError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - 하단 조작부

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("이름")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                // 사용자가 친 것만 '고쳤다' 로 친다.
                // onChange 로 잡으면 역지오코딩이 채운 값까지 편집으로 오인한다.
                TextField("집", text: Binding(
                    get: { name },
                    set: { name = $0; nameEdited = true }
                ))
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.trailing)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("도착 반경")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(radius))m")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Slider(value: $radius, in: Self.minRadius...Self.maxRadius, step: 10)
                    .tint(tint)
                Text("이 반경 안에 들어오면 도착으로 봅니다. 아파트 단지는 넉넉하게 잡으세요.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if currentLocation != nil {
                    Button {
                        moveToCurrentLocation()
                    } label: {
                        Label("현재 위치", systemImage: "location.fill")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Text(String(format: "%.5f, %.5f", center.latitude, center.longitude))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(16)
    }

    // MARK: - 동작

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = HomePlace(
            name: trimmed.isEmpty ? "집" : trimmed,
            coordinate: center,
            arrivalRadius: radius
        )
        onSave(place)
        dismiss()
    }

    private func moveToCurrentLocation() {
        guard let currentLocation else { return }
        withAnimation {
            camera = .region(
                MKCoordinateRegion(
                    center: currentLocation.coordinate,
                    latitudinalMeters: 500,
                    longitudinalMeters: 500
                )
            )
        }
    }

    private func choose(_ item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        results = []
        query = ""
        if !nameEdited, let found = item.name { name = found }
        withAnimation {
            camera = .region(
                MKCoordinateRegion(center: coordinate, latitudinalMeters: 400, longitudinalMeters: 400)
            )
        }
    }

    private func runSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        searchTask?.cancel()
        searchError = nil
        searchTask = Task {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            // 보고 있는 곳 주변을 먼저 찾는다. 같은 이름의 가게가 전국에 널려 있다.
            request.region = MKCoordinateRegion(
                center: center,
                latitudinalMeters: 30_000,
                longitudinalMeters: 30_000
            )

            do {
                let response = try await MKLocalSearch(request: request).start()
                guard !Task.isCancelled else { return }
                results = Array(response.mapItems.prefix(6))
                if results.isEmpty { searchError = "검색 결과가 없습니다." }
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                searchError = "검색에 실패했습니다."
            }
        }
    }

    /// 지도를 멈춘 곳의 주소로 이름을 채워 준다. 사용자가 손댄 이름은 건드리지 않는다.
    private func scheduleReverseGeocode() {
        guard !nameEdited else { return }

        geocodeTask?.cancel()
        let target = center
        geocodeTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            let location = CLLocation(latitude: target.latitude, longitude: target.longitude)
            guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first,
                  !Task.isCancelled, !nameEdited
            else { return }

            if let found = placemark.name ?? placemark.thoroughfare {
                name = found
                // 역지오코딩으로 채운 값은 '사용자가 고친 것' 이 아니다.
                nameEdited = false
            }
        }
    }

    private static func addressLine(_ item: MKMapItem) -> String {
        let placemark = item.placemark
        return [placemark.locality, placemark.thoroughfare, placemark.subThoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}
