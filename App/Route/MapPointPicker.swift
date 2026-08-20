import CoreLocation
import MapKit
import SwiftUI

/// 지도를 움직여 한 점을 고른다.
///
/// **검색으로는 못 찾는 자리가 늘 있다.** 버스정류장은 애플 지도에 시설로 등록되어
/// 있지 않아 "환승로터리" 를 치면 근처 편의점이 나온다. 공공데이터 쪽도 서울 정류장의
/// 좌표는 주지 않는다. 골목이나 아파트 후문처럼 아예 이름이 없는 자리도 있다.
///
/// 그런데 그 자리가 어딘지는 **쓰는 사람이 안다.** 지도를 움직여 찍게 하면 API 가
/// 무엇을 갖고 있든 상관이 없다.
///
/// 정확도가 걱정될 자리가 아니다. 좌표는 "지금 어느 구간인가" 판정에만 쓰이고
/// 이탈 기준이 1km 다. 손으로 찍어도 충분히 맞는다.
struct MapPointPicker: View {

    /// 지도를 처음 놓을 자리.
    let start: CLLocationCoordinate2D
    /// 무엇을 찍는 중인지. "환승로터리" 처럼 사용자가 적은 이름을 그대로 보여 준다.
    let title: String
    /// 근처 정류장을 찾아 준다. 없으면 지도만 쓴다.
    var findStops: ((CLLocationCoordinate2D) async -> [BusStop])?

    /// 이름으로 정류장을 찾아 준다. 없으면 검색에서 정류장이 빠지고 장소만 나온다.
    ///
    /// **좌표 조회와 따로 받는다.** 근접 조회는 반경이 고정이라 화면 밖의 정류장을
    /// 못 찾는다 — 검색은 지도를 옮기기 위한 것이니 지금 보이는 자리와 무관해야 한다.
    var searchStops: ((String) async -> [BusStop])?
    /// 이름과 좌표를 함께 돌려준다. 정류장을 골랐으면 그 공식 이름이 온다.
    var onPick: (String?, CLLocationCoordinate2D) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition
    @State private var center: CLLocationCoordinate2D
    @State private var stops: [BusStop] = []
    @State private var lookup: Task<Void, Never>?
    /// 마지막으로 조회한 자리. 거의 안 움직였을 때 재조회를 건너뛰는 데 쓴다.
    @State private var lastAsked: CLLocationCoordinate2D?

    // MARK: 검색
    @State private var query = ""
    @State private var search = PlaceSearch()
    @State private var namedStops: [BusStop] = []
    @State private var nameLookup: Task<Void, Never>?

    private let accent = Color(red: 0.42, green: 0.85, blue: 0.62)

    init(start: CLLocationCoordinate2D, title: String,
         findStops: ((CLLocationCoordinate2D) async -> [BusStop])? = nil,
         searchStops: ((String) async -> [BusStop])? = nil,
         onPick: @escaping (String?, CLLocationCoordinate2D) -> Void) {
        self.start = start
        self.title = title
        self.findStops = findStops
        self.searchStops = searchStops
        self.onPick = onPick
        // 300m 폭. 정류장 하나를 고르는 데 알맞은 배율이다 —
        // 더 넓으면 어느 쪽 정류장인지 못 고르고, 더 좁으면 길을 잃는다.
        _camera = State(initialValue: .region(MKCoordinateRegion(
            center: start, latitudinalMeters: 300, longitudinalMeters: 300
        )))
        _center = State(initialValue: start)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $camera) {
                    // 근처 정류장을 지도에 함께 찍는다. 어느 쪽 정류장인지는
                    // 방향이 있어야 고를 수 있다 — 같은 이름이 길 양쪽에 있다.
                    ForEach(stops) { stop in
                        Annotation(stop.name, coordinate: stop.coordinate) {
                            Image(systemName: "bus.fill")
                                .font(.system(size: 11))
                                .padding(5)
                                .background(Circle().fill(.white))
                                .foregroundStyle(.black)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .all))
                // **끝날 때까지 기다리지 않는다.** `.onEnd` 는 제스처가 완전히
                // 멈춰야 불리는데, 손을 떼고 관성 스크롤이 잦아들기까지 기다리게
                // 되어 정류장이 늦게 나타났다. `.continuous` 로 받아 **잠깐
                // 멈추면**(0.25초) 조회한다 — 움직이는 내내 부르지 않으면서도
                // 눈에 띄게 빠르다.
                .onMapCameraChange(frequency: .continuous) { context in
                    center = context.region.center
                    refreshStops()
                }
                .ignoresSafeArea(edges: .bottom)

                // 십자선은 지도 한가운데 고정된다. 핀을 끄는 것보다 이쪽이 낫다 —
                // 손가락이 가리는 지점을 찍게 되지 않는다.
                crosshair

                VStack(spacing: 0) {
                    searchBar
                    Spacer()
                    footer
                }
            }
            .navigationTitle(title.isEmpty ? "위치 고르기" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
            .task { refreshStops() }
        }
    }

    /// 지도를 옮기기 위한 검색.
    ///
    /// **고르는 것이 아니라 옮기는 것이다.** 결과를 누르면 지도가 그 자리로 가고,
    /// 확정은 기존처럼 십자선으로 한다 — 정류장은 같은 이름이 길 양쪽에 있어서
    /// 검색 결과를 그대로 집으면 반대 방향을 찍게 된다. 이 화면이 십자선을 쓰는
    /// 이유가 그것이다.
    @ViewBuilder
    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                TextField("정류장·장소 검색", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onChange(of: query) { _, new in runSearch(new) }
                if search.isSearching {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                        namedStops = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if !query.isEmpty && (!namedStops.isEmpty || !search.hits.isEmpty) {
                ScrollView {
                    VStack(spacing: 0) {
                        // **정류장이 먼저다.** 애플 지도에 버스정류장이 시설로 없어서
                        // "환승로터리" 를 치면 근처 편의점이 나온다 — `PlacePicker` 와
                        // 같은 판단이다.
                        ForEach(namedStops) { stop in
                            resultRow(stop.name, context: stop.number.map { "\($0)" },
                                      symbol: "bus.fill", coordinate: stop.coordinate)
                        }
                        ForEach(search.hits) { hit in
                            resultRow(hit.name, context: hit.context,
                                      symbol: "mappin", coordinate: hit.coordinate)
                        }
                    }
                }
                .frame(maxHeight: 260)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 6)
            } else if !query.isEmpty, let message = search.lastError, !search.isSearching {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func resultRow(
        _ name: String, context: String?, symbol: String, coordinate: CLLocationCoordinate2D
    ) -> some View {
        Button {
            move(to: coordinate)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 18)
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 14))
                    if let context {
                        Text(context).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 검색 결과로 지도를 옮긴다. 300m 폭은 이 화면이 처음 열릴 때와 같다 —
    /// 정류장 하나를 고를 수 있는 배율이다.
    private func move(to coordinate: CLLocationCoordinate2D) {
        query = ""
        namedStops = []
        center = coordinate
        lastAsked = nil                 // 자리가 바뀌었으니 정류장을 다시 묻는다
        withAnimation(.easeInOut(duration: 0.35)) {
            camera = .region(MKCoordinateRegion(
                center: coordinate, latitudinalMeters: 300, longitudinalMeters: 300))
        }
        refreshStops()
    }

    /// 이름으로 찾는다. 정류장과 장소를 함께 본다.
    private func runSearch(_ text: String) {
        search.near = center
        search.search(text)

        nameLookup?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let searchStops, trimmed.count >= 2 else {
            namedStops = []
            return
        }
        nameLookup = Task {
            // 한 글자씩 칠 때마다 공공데이터를 부르지 않는다.
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            let found = await searchStops(trimmed)
            guard !Task.isCancelled else { return }
            namedStops = found
        }
    }

    private var crosshair: some View {
        ZStack {
            Circle()
                .strokeBorder(accent, lineWidth: 2)
                .frame(width: 22, height: 22)
            Circle()
                .fill(accent)
                .frame(width: 5, height: 5)
            // 지도에 닿는 점을 정확히 알려 준다.
            Rectangle().fill(accent.opacity(0.7)).frame(width: 1, height: 34)
            Rectangle().fill(accent.opacity(0.7)).frame(width: 34, height: 1)
        }
        .allowsHitTesting(false)
        .shadow(radius: 2)
    }

    /// 지도가 잠깐 멈추면 그 자리의 정류장을 찾는다.
    ///
    /// **움직이는 내내 부르지는 않는다.** 공공데이터 쪽 요청을 아끼는 것이기도
    /// 하고, 목록이 계속 흔들리면 고를 수가 없다. 그래서 요청을 걸어 두고 잠깐
    /// 기다린다 — 그 사이에 카메라가 또 움직이면 앞의 것을 버린다(디바운스).
    ///
    /// `.onEnd` 를 기다리던 것보다 빠르다. 손을 떼고 관성이 잦아들 때까지가
    /// 아니라, 손가락이 잠시 멈추는 순간에 이미 나타난다.
    private func refreshStops() {
        guard let findStops else { return }

        // 거의 안 움직였으면 다시 묻지 않는다. 근접 조회의 반경이 고정이라
        // 이 정도 안에서는 결과가 같다.
        if let asked = lastAsked,
           CLLocation(latitude: asked.latitude, longitude: asked.longitude)
            .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
            < Self.refetchThreshold {
            return
        }

        lookup?.cancel()
        let here = center
        lookup = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            lastAsked = here
            let found = await findStops(here)
            guard !Task.isCancelled else { return }
            stops = found
        }
    }

    /// 이만큼 안 움직였으면 다시 묻지 않는다(m).
    private static let refetchThreshold: CLLocationDistance = 60

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 10) {
            if !stops.isEmpty {
                // **정류장을 고르면 공식 이름과 정확한 좌표가 함께 들어온다.**
                // 애플 지도가 모르는 것을 공공데이터는 안다.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(stops) { stop in
                            Button {
                                onPick(stop.name, stop.coordinate)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(stop.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    if let number = stop.number {
                                        Text("\(number)")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 46)
            }

            Text(String(format: "%.5f, %.5f", center.latitude, center.longitude))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)

            Button {
                onPick(nil, center)
                dismiss()
            } label: {
                Text("여기로 정하기")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(accent))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.regularMaterial)
    }
}
