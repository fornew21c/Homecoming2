import MapKit
import SwiftUI

/// 귀가자가 **지금 어디쯤인가**를 지도에 그대로 보여 준다.
///
/// 카드(`HomecomingJourneyCard`)는 "얼마나 남았나" 에 답한다 — 남은 거리, 도착 예정,
/// 노선도 위의 점. 그런데 그 값들로는 "어디쯤인가" 를 알 수 없다. 남은거리 3.2km 는
/// 어느 방향 3.2km 인지 말해 주지 않고, 노선도의 점은 순서를 그린 것이라 지리가 아니다.
/// 이 뷰가 그 질문에 답한다.
///
/// **좌표가 없으면 아무것도 그리지 않는다.** 첫 위치 보고 전이거나, 이 필드를 모르는
/// 서버가 보낸 갱신이면 지도 자리를 아예 만들지 않는다 — 빈 회색 사각형은 "위치를
/// 모른다" 보다 "고장났다" 로 읽힌다.
struct HomecomingJourneyMap: View {

    let travelerName: String
    let destinationName: String
    let state: HomecomingAttributes.ContentState

    /// 카드가 쓰는 것과 같은 값. `measuredAt` 을 모르는 서버에서 낡음을 판단하는 폴백이다.
    let lastFixedAt: Date?

    /// 어느 귀가인가. 경로 좌표를 받아 올 열쇠다. 없으면 선 없이 점만 찍는다.
    let sessionID: String?

    /// 세션별 경로 보관소. 뷰가 직접 요청하지 않고 여기에 맡긴다 —
    /// 뷰는 다시 그려질 때마다 `.task` 를 도는데 그때마다 요청이 나가면 안 된다.
    let routes: RouteGeometryStore


    /// 카메라를 상태로 들고 있는다.
    ///
    /// `.automatic` 에 맡기면 갱신이 올 때마다 프레임이 새로 잡혀 지도가 튄다.
    /// 좌표가 바뀔 때만 우리가 계산해 옮긴다.
    @State private var camera: MapCameraPosition = .automatic

    /// 귀가자 마커의 맥동. `onAppear` 에서 켜고 애니메이션이 되풀이한다.
    @State private var pulsing = false

    var body: some View {
        if let traveler = state.travelerCoordinate {
            content(traveler: traveler, home: state.homeCoordinate)
                // 귀가 한 건에 한 번만 받는다. `id:` 가 세션이라 다른 귀가로
                // 바뀔 때만 다시 돈다. 보관소가 중복 요청을 한 번 더 막는다.
                .task(id: sessionID) {
                    guard let sessionID else { return }
                    await routes.load(sessionID: sessionID)
                }
        }
    }

    /// 지도에 찍을 경로의 정류장. **집은 뺀다.**
    ///
    /// 경로의 마지막 정류장은 집 자신이다(마지막 도보 구간의 도착지 이름이
    /// `집` 이다). 그걸 그대로 찍으면 집 마커와 겹쳐 **집이 두 개로 보인다**
    /// (2026-08-20 화면에서 그랬다). 도착지는 이미 자기 마커가 있다.
    ///
    /// 이름으로 걸러내지 않고 자리로 걸러낸다 — 집 이름은 사용자가 정하는 값이라
    /// `집` 이 아닐 수 있고, 그때도 겹치는 건 마찬가지다.
    private func routeStops(
        excluding home: CLLocationCoordinate2D?,
        and traveler: CLLocationCoordinate2D
    ) -> [RouteGeometry.Stop] {
        guard let geometry else { return [] }

        // **마지막 정류장은 도착지다.** 경로의 정류장은 이동 구간마다 하나씩,
        // 순서대로 만들어진다(서버 `route_geometry`). 그러니 마지막은 언제나
        // 집이다. 거리로 걸러 보려 했는데 안 걸렸다 — MapKit 도보 경로가 집
        // 좌표에 정확히 닿지 않아서(단지 안쪽은 보행로 자료가 없다) 그 점이
        // 집에서 100m 넘게 떨어져 있었다. 구조로 아는 것을 거리로 짐작할 이유가 없다.
        var stops = geometry.stops
        if !stops.isEmpty { stops.removeLast() }

        // 그래도 집 자리와 겹치는 것이 남으면 뺀다. 경로 중간에 집 앞을 지나는
        // 경우가 있다.
        // **귀가자와 겹치는 정류장도 뺀다.** 정류장에 서 있으면 흰 버스 아이콘이
        // 귀가자 점을 덮어, 지금 어디 있는지가 화면에서 사라진다(2026-08-20 아파트단지
        // 1.3단지에서 그랬다). 이 화면이 답하는 질문이 그것이라 귀가자가 이긴다.
        return stops.filter { stop in
            let here = CLLocation(latitude: stop.coordinate.latitude,
                                  longitude: stop.coordinate.longitude)
            if here.distance(from: CLLocation(latitude: traveler.latitude,
                                              longitude: traveler.longitude))
                <= Self.travelerOverlapMeters { return false }
            guard let home else { return true }
            return here.distance(from: CLLocation(latitude: home.latitude,
                                                  longitude: home.longitude))
                > Self.homeOverlapMeters
        }
    }

    /// 이 거리 안의 정류장은 귀가자와 같은 자리로 본다. 마커 지름이 화면에서
    /// 그만큼을 차지한다.
    private static let travelerOverlapMeters: CLLocationDistance = 40

    /// 이 거리 안의 정류장은 집과 같은 자리로 본다. 도착 반경 하한(100m)보다
    /// 작게 둔다 — 집 앞 정류장은 남겨야 "어디서 내리는지" 가 보인다.
    private static let homeOverlapMeters: CLLocationDistance = 60

    /// 받아 둔 경로. 아직 안 왔거나 경로 없는 귀가면 nil 이다.
    private var geometry: RouteGeometry? {
        guard let sessionID, let found = routes.geometry(for: sessionID), !found.isEmpty
        else { return nil }
        return found
    }

    private func content(traveler: CLLocationCoordinate2D, home: CLLocationCoordinate2D?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                // 선을 귀가자 마커보다 먼저 넣는다. 뒤에 넣은 것이 위에 그려지므로,
                // 선이 점을 덮으면 지금 자리가 가려진다.
                //
                // 집 도착 반경. **"곧 도착" 이 왜 떴는지를 지도가 설명한다.**
                // 서버가 이 반경 안에서 단계를 올리므로, 판정에 쓰는 값과 같은
                // 숫자를 그린다.
                if let home, let radius = state.homeRadius, radius > 0 {
                    MapCircle(center: home, radius: CLLocationDistance(radius))
                        .foregroundStyle(.orange.opacity(0.10))
                        .stroke(.orange.opacity(0.45), lineWidth: 1)
                }

                if let geometry {
                    // **도보는 점선, 탈것은 실선.** 네이버 지도가 그렇게 한다.
                    // 지하철까지 패턴을 나누지 않는다 — 지나온/남은 구간의
                    // 진하기와 곱해져 "흐린 파선" 같은 조합이 생기고, 그러면
                    // 아무것도 안 읽힌다. 지하철 구분은 정류장 아이콘이 한다.
                    //
                    // **지나온 구간은 회색으로 얇게.** 자르는 자리는 서버가 준 진행도다 —
                    // 카드의 노선도 점과 **같은 값**이다(`pieces(of:traveler:)`).
                    ForEach(pieces(of: geometry, traveler: traveler)) { piece in
                        MapPolyline(coordinates: piece.points)
                            .stroke(piece.passed ? Self.passedColor : state.tint.opacity(0.95),
                                    style: Self.stroke(walk: piece.isWalk,
                                                       passed: piece.passed))
                    }

                    // **이 경로가 지나는 정류장만 찍는다.**
                    //
                    // 처음에는 근처 정류장을 전부 찍었다(집 지정 화면과 같은
                    // 자료). 확대하면 흰 버스 아이콘이 여섯 개씩 겹쳐 이름이
                    // 가려지고 선이 안 보였다. 가족이 알아야 하는 것은 "이 사람이
                    // 어디를 거쳐 오는가" 이고, 그건 경로의 정류장이다.
                    //
                    // 환승 지점은 테두리를 굵게 해 구분한다 — 갈아타며 기다리는
                    // 자리가 "지금 어디쯤" 을 읽는 데 가장 쓸모 있는 점이다.
                    ForEach(routeStops(excluding: home, and: traveler)) { stop in
                        Annotation(stop.name, coordinate: stop.coordinate) {
                            // **수단 아이콘을 쓴다.** 전부 버스로 그리던 동안
                            // `서강대역` 도 버스로 나왔다 — 지하철로 갈아타는
                            // 자리인데 화면은 버스라고 말했다. 아이콘 이름은
                            // 카드·잠금화면과 같은 표를 쓴다(`Transport.symbolName`).
                            Image(systemName: stop.symbolName)
                                .font(.system(size: 9))
                                .padding(4)
                                .background(Circle().fill(.white))
                                .foregroundStyle(.black)
                                .overlay(
                                    Circle().stroke(state.tint,
                                                    lineWidth: stop.isTransfer ? 2.5 : 0))
                        }
                    }
                }

                // 귀가자. 이름을 같이 적는다 — 여럿을 지켜볼 때 어느 지도인지
                // 카드까지 올라가서 확인해야 하면 지도 두 개가 헷갈린다.
                Annotation(travelerName, coordinate: traveler) {
                    ZStack {
                        // **숨 쉬는 테두리.** 지금 벌어지고 있는 일이라는 신호다.
                        // 도착하면 멈춘다 — 끝난 귀가에서 계속 뛰면 아직 오는 중
                        // 처럼 읽힌다.
                        Circle()
                            .fill(state.tint.opacity(0.25))
                            .frame(width: 34, height: 34)
                            .scaleEffect(pulsing && !state.stage.isFinished ? 1.35 : 0.85)
                            .opacity(pulsing && !state.stage.isFinished ? 0.25 : 0.7)
                        Circle()
                            .fill(state.tint)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2.5))
                    }
                    .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                               value: pulsing)
                    .onAppear { pulsing = true }
                }

                // 집. 점 하나만 있으면 축척을 알 수 없어 "가까운지" 가 안 읽힌다.
                if let home {
                    Marker(destinationName, systemImage: "house.fill", coordinate: home)
                        .tint(.orange)
                }
            }
            // 시설 표시를 켜 둔다. 정류장 주변이 어떤 곳인지 같이 읽힌다.
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .all))
            // **주는 만큼 다 쓴다.** 높이를 여기서 정하지 않는다.
            //
            // `귀가` 탭이 상단에서 `지도 | 카드` 를 가르고, 지도 쪽은 남는 공간을
            // 통째로 준다(2026-08-28). 그러니 비율을 짐작할 이유가 없다.
            //
            // 예전에는 `containerRelativeFrame(.vertical) { min(max(h*0.72, 300), 620) }`
            // 이었다. 그 값들은 지도가 스크롤 안에 있던 시절의 타협이다 —
            // 200pt 로는 28km 가 손톱만 하게 눌렸고, 키우면 화면 밖으로 나갔다.
            // 상한 620 은 "그 이상은 어차피 한 화면에 안 들어와서" 둔 값이라
            // 스크롤이 없어진 지금은 전제가 사라졌다.
            //
            // **이 변경이 2026-08-25 사고를 구조로 없앤다.** 귀가자 마커는 영역의
            // 가장자리에 있고(`region()` 이 bbox × 1.25) 지도 아래쪽이 화면 밖이라
            // 그 잘린 띠에 들어갔다 — 지도를 열었는데 사람이 안 보였다. 지도가
            // 자기 화면을 다 쓰면 잘릴 띠가 없다.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
            .onAppear { camera = .region(region(traveler: traveler, home: home)) }
            // 좌표가 실제로 바뀐 갱신에서만 옮긴다. 단계나 문구만 바뀐 갱신에
            // 카메라를 다시 잡으면 사용자가 확대해 둔 것이 매번 풀린다.
            .onChange(of: TravelerFrame(traveler: traveler, home: home)) { _, frame in
                withAnimation(.easeInOut(duration: 0.4)) {
                    camera = .region(region(traveler: frame.traveler, home: frame.home))
                }
            }
            // 경로가 뒤늦게 도착한다(서버에서 받아 온다). 그때 한 번 더 잡아야
            // 선이 프레임 밖으로 잘리지 않는다 — 안 하면 처음 잡은 두 점 기준
            // 사각형에 갇혀 우회 구간이 화면 밖에 남는다.
            .onChange(of: geometry?.polyline.count ?? 0) { _, _ in
                withAnimation(.easeInOut(duration: 0.4)) {
                    camera = .region(region(traveler: traveler, home: home))
                }
            }

            // **지도는 거리 숫자보다 강하게 "지금" 으로 읽힌다.** 점이 찍혀 있으면
            // 그 자리에 있는 것처럼 보이므로, 낡은 값일 때는 반드시 말해 줘야 한다.
            // 문턱(3분)과 `measuredAt` 우선 규칙은 노선도의 "N분 전 확인" 과 같다.
            if let note = staleNote {
                Label(note, systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange.opacity(0.9))
            }

            // **점과 색이 어긋난 이유를 화면이 말해야 한다.**
            //
            // 이탈하면 서버의 진행도가 그 자리에 서므로 지나온/남은 색 분리도 멈추고,
            // 귀가자 점만 선 밖으로 나간다. 그것이 이탈 신호다 — 지금까지 이 화면에는
            // 이탈을 알 방법이 아예 없었다. 그런데 설명이 없으면 어긋난 그림이
            // **고장으로 읽힌다.** 이 프로젝트가 `estimateSource` 를 만든 이유가
            // 그것이다("진단값이 거짓이면 진단을 방해한다").
            //
            // 문구는 `Anomaly.offRoute.title` 을 그대로 쓴다. 같은 사건을 카드와
            // 지도가 다른 말로 부르면 두 가지 일이 난 것처럼 보인다.
            if state.estimateSource == "offRoute" {
                Label(
                    "\(HomecomingAttributes.Anomaly.offRoute.title) — 지나온 표시는 여기서 멈춰요",
                    systemImage: HomecomingAttributes.Anomaly.offRoute.symbolName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(HomecomingAttributes.Anomaly.offRoute.tint.opacity(0.9))
            }
        }
    }

    /// 카메라를 다시 잡을지 가리는 열쇠. 좌표만 본다.
    private struct TravelerFrame: Equatable {
        var traveler: CLLocationCoordinate2D
        var home: CLLocationCoordinate2D?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.traveler.latitude == rhs.traveler.latitude
                && lhs.traveler.longitude == rhs.traveler.longitude
                && lhs.home?.latitude == rhs.home?.latitude
                && lhs.home?.longitude == rhs.home?.longitude
        }
    }

    /// 그려야 할 것이 다 들어오는 사각형 — 귀가자, 집, 그리고 **남은** 경로.
    ///
    /// **지나온 구간은 담지 않는다.** 처음에는 경로 전체를 담았는데, 28km 를 한
    /// 화면에 넣으면 정작 볼 것이 안 보인다 — 도착 반경 원(120m)은 픽셀 이하가
    /// 되고, 정류장 마커가 겹쳐 뭉친다. 집 근처에 다 와서도 화면은 여의도까지
    /// 보여 주고 있었다(2026-08-20).
    ///
    /// 가족이 궁금한 것은 **앞으로 갈 길**이다. 남은 구간만 담으면 귀가가
    /// 진행되면서 지도가 저절로 마지막 구간으로 확대된다 — 가장 중요한 몇 분에
    /// 가장 자세해진다. 서버 README 가 "마지막 몇 분이 가족에게 가장 중요한
    /// 구간" 이라고 적어 둔 것과 같은 방향이다.
    ///
    /// 최소 폭을 두는 이유는 도착 직전에 점들이 겹치기 때문이다 — 그대로 맞추면
    /// span 이 0 에 가까워져 지도가 건물 안까지 파고든다.
    private func region(
        traveler: CLLocationCoordinate2D,
        home: CLLocationCoordinate2D?
    ) -> MKCoordinateRegion {
        var points = [traveler]
        if let home { points.append(home) }
        if let geometry {
            for piece in pieces(of: geometry, traveler: traveler) where !piece.passed {
                points.append(contentsOf: piece.points)
            }
        }

        let latitudes = points.map(\.latitude)
        let longitudes = points.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max()
        else {
            return MKCoordinateRegion(center: traveler, span: MKCoordinateSpan(
                latitudeDelta: Self.minimumSpan, longitudeDelta: Self.minimumSpan))
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)

        // 1.25 배는 여백이다. 딱 맞추면 끝점이 테두리에 붙어 핀이 잘린다.
        // 두 점만 담던 때의 1.6 보다 작다 — 경로가 이미 프레임을 넓히고 있어서
        // 같은 배수를 쓰면 지도가 필요 이상으로 멀어진다.
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.25, Self.minimumSpan),
            longitudeDelta: max((maxLon - minLon) * 1.25, Self.minimumSpan)))
    }

    /// 지나온 길의 색. **색상 자체를 뺀다.**
    ///
    /// 예전에는 같은 색의 진하기만 달랐다(`tint` 의 0.22 대 0.75). 지도에는 시설
    /// 표시와 도로가 함께 그려져 있어서, 같은 색의 흐린 선은 그 배경에 묻히고
    /// **어디까지 왔는지가 흘깃 봐서 안 읽혔다**(2026-08-21). 파란 선과 회색 선은
    /// 색상이 달라 한눈에 갈린다.
    ///
    /// 지우지 않고 남겨 두는 이유는 지나온 길도 정보이기 때문이다 — 어디를 거쳐
    /// 왔는지가 "이 사람이 지금 어느 길에 있나" 를 읽는 데 쓰인다.
    private static let passedColor = Color(white: 0.62).opacity(0.6)

    /// 선 굵기와 점선 여부. 도보는 점, 탈것은 실선이고, **지나온 길은 얇다.**
    ///
    /// 색상에 굵기를 한 번 더 얹는다. 색만으로 가르면 색약인 사람에게는 갈리지
    /// 않는다 — 굵기는 색과 무관하게 읽힌다.
    ///
    /// **도보는 동그란 점으로 그린다.** 길이가 0 에 가까운 dash 에 둥근 끝을 주면
    /// 지름이 선 굵기와 같은 점이 된다. 예전에는 `dash: [2, 6]` 에 굵기 5 였는데,
    /// 둥근 끝이 양쪽으로 굵기의 절반씩 더 붙어 각 점이 **길이 7pt · 폭 5pt 의
    /// 뭉툭한 알약**이 됐다(2026-08-21 화면에서 그렇게 보였다). 도보는 탈것보다
    /// 가벼운 구간이라 얇은 것이 뜻에도 맞는다.
    private static func stroke(walk: Bool, passed: Bool) -> StrokeStyle {
        guard walk else {
            return StrokeStyle(lineWidth: passed ? 3 : 5, lineCap: .round, lineJoin: .round)
        }
        let width: CGFloat = passed ? 2.5 : 3.5
        return StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round,
                           dash: [0.01, width * 2.2])
    }

    // MARK: - 진행도로 자르기
    //
    // **지나온 쪽과 남은 쪽을 나누는 자리는 서버가 준다.** `state.travelledMeters` 다.
    // 카드의 노선도 점이 쓰는 값과 **같다** — 진행도를 한 벌로 합친 것이 이 묶음이다.
    //
    // 예전에는 이 화면이 스스로 계산했다: 좌표열에서 귀가자에게 가장 가까운 점.
    // 정상 이동에서는 카드와 평균 36m 로 맞았지만 예외에서 갈라졌다(2026-08-20 실측,
    // 28.4km 경로) — GPS 가 역행하면 7,404m, 경로를 1.5km 벗어나면 4,349m. 한쪽은
    // 되돌아가고 다른 쪽은 앞으로 튀니 두 화면이 서로 다른 말을 했다.
    //
    // **귀가자 점은 그대로 GPS 다.** 진행도만 통일하고 실제 자리는 꾸미지 않는다.
    // 그래서 이탈하면 색 분리는 멈추고 점만 선 밖으로 나간다 — 그것이 이탈 신호다.

    /// 지도에 그릴 선 한 토막.
    ///
    /// **구간과 1:1 이 아니다.** 진행 지점이 구간 안에 있으면 그 구간이 지나온 쪽과
    /// 남은 쪽 둘로 갈린다. 구간 단위로만 흐리게 하던 때는 18.7km 지하철 구간(이
    /// 경로의 66%)을 타는 동안 색이 한 번도 안 바뀌어서, 카드의 점은 내려가는데
    /// 지도는 멈춰 있는 것처럼 보였다.
    private struct Piece: Identifiable {
        let id: String
        let points: [CLLocationCoordinate2D]
        let isWalk: Bool
        let passed: Bool
    }

    /// 경로를 진행 지점에서 잘라 토막들로 만든다. 자르는 계산은 `RouteTrail` 이
    /// 한다 — 그 파일에 축(구간별 누적)과 실측 근거가 적혀 있다.
    private func pieces(of geometry: RouteGeometry, traveler: CLLocationCoordinate2D) -> [Piece] {
        let segments = Self.drawable(geometry)
        let trail = RouteTrail(segments: segments.map(\.points))

        // **도착하면 전부 지나온 것으로 그린다.** 도착 판정의 주인은 서버의 `stage`
        // 이지 거리가 아니다 — 카드도 같은 규칙으로 점을 마지막 정류장에 세운다
        // (`RouteStripView.position`). 서버는 도착 때 진행도로 경로 전체 길이를
        // 보내지만(`route_travelled`), 그 필드를 모르는 옛 서버에서도 두 화면이
        // 같이 끝에 닿아야 한다.
        let cut: Double
        if state.stage.isFinished {
            cut = trail.length
        } else if let travelled = state.travelledMeters {
            cut = Double(travelled)
        } else {
            cut = trail.travelled(nearestTo: traveler)
        }

        var pieces: [Piece] = []
        for (segment, part) in zip(segments, trail.cut(at: cut)) {
            // 한 점짜리 토막은 그리지 않는다. 진행 지점이 구간의 끝에 딱 닿으면
            // 한쪽이 그렇게 되는데, `MapPolyline` 에 점 하나를 주면 선이 아니다.
            if part.passed.count >= 2 {
                pieces.append(Piece(id: "\(segment.id)-지나옴", points: part.passed,
                                    isWalk: segment.isWalk, passed: true))
            }
            if part.remaining.count >= 2 {
                pieces.append(Piece(id: "\(segment.id)-남음", points: part.remaining,
                                    isWalk: segment.isWalk, passed: false))
            }
        }
        return pieces
    }

    /// 그릴 구간 목록. 구간이 안 오는 옛 서버에서는 이어붙인 좌표열을 구간 하나로
    /// 삼는다 — 그리는 길을 둘로 두면 한쪽만 고치는 실수가 난다.
    ///
    /// 그 경우 이음이 누적에 섞이지만(`RouteTrail.segments` 주석의 97.9m), 진행도도
    /// 같이 안 오므로 견줄 축이 없다 — 폴백은 자기 좌표열 안에서만 자기를 자른다.
    private static func drawable(_ geometry: RouteGeometry) -> [RouteGeometry.Segment] {
        if !geometry.segments.isEmpty { return geometry.segments }
        guard geometry.polyline.count >= 2 else { return [] }
        return [RouteGeometry.Segment(mode: "", points: geometry.polyline, id: 0)]
    }

    /// 약 250m. 도착해서 두 점이 겹쳤을 때 쓰는 최소 폭이다.
    private static let minimumSpan = 0.0025

    /// "N분 전 확인". 문턱 미만이면 아무것도 적지 않는다.
    ///
    /// `measuredAt`(측정 시각)을 먼저 본다. 받은 시각으로 판단하면 APNs 가 갱신을
    /// 붙잡고 있다가 내려보낸 경우에 낡은 자리를 방금 자리로 보여 준다.
    private var staleNote: String? {
        guard let at = state.measuredAt ?? lastFixedAt else { return nil }
        let minutes = Int(Date().timeIntervalSince(at) / 60)
        guard minutes >= 3 else { return nil }
        return "\(minutes)분 전 위치"
    }
}

extension HomecomingAttributes.ContentState {

    /// 갱신값의 위도·경도를 지도가 쓰는 형으로. 둘 중 하나라도 없으면 nil 이다.
    var travelerCoordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var homeCoordinate: CLLocationCoordinate2D? {
        guard let homeLat, let homeLon else { return nil }
        return CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon)
    }
}
