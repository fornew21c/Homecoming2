import ActivityKit
import Foundation
import SwiftUI

/// 귀가마중 Live Activity 가 주고받는 데이터 정의.
///
/// `HomecomingAttributes` 자체는 액티비티가 시작될 때 한 번 정해지고 바뀌지 않는 값이고,
/// `ContentState` 는 이동하는 동안 계속 갱신되는 값이다.
/// 이 파일은 앱 타겟과 위젯 익스텐션 타겟 양쪽에 모두 포함되어야 한다.
struct HomecomingAttributes: ActivityAttributes {

    // MARK: - 고정 값

    /// 귀가하는 사람. 가족 화면에는 "아빠", "엄마" 처럼 호칭으로 표시된다.
    var travelerName: String

    /// 도착지 이름. 보통 "집".
    var destinationName: String

    /// 출발 시각 (액티비티 시작 시점).
    var departedAt: Date

    /// 이 액티비티가 어느 귀가 건에 속하는지.
    ///
    /// 서버가 가족 기기에 액티비티를 띄우면, 그 기기가 갱신 토큰을 서버로 올린다.
    /// 그때 **어느 귀가의 토큰인지** 말해 줄 방법이 이것뿐이다.
    /// 없으면 서버는 받은 토큰을 어디에 써야 할지 알 수 없다.
    var sessionID: String?

    /// 이 액티비티를 **누가 보는가**.
    ///
    /// 같은 귀가 한 건에 대해 액티비티가 여러 개 뜬다 — 귀가자 본인 폰에 하나,
    /// 기다리는 가족 각자의 폰에 하나씩. 필요한 정보가 서로 다르므로 화면도 달라야 한다.
    /// 액티비티가 사는 동안 바뀌지 않으므로 갱신값이 아니라 고정값이다.
    var audience: Audience = .traveler

    /// 노선도에 그릴 정류장 목록. 경로 없이 시작한 귀가면 nil 이다.
    ///
    /// **옵셔널이어야 한다.** 경로 없는 귀가와, 이 변경 전에 시작된 액티비티가
    /// 안 깨진다. 서버가 이 키를 안 보내는 경우도 그대로 통과한다.
    var routeShape: RouteShape?

    // MARK: - 갱신 값

    struct ContentState: Codable, Hashable {

        /// 귀가 진행 단계.
        var stage: Stage

        /// 이동 수단.
        var transport: Transport

        /// 도착 예정 시각. 위젯은 이 값으로 남은 시간을 스스로 카운트다운하므로
        /// 매 분 푸시를 보내지 않아도 화면이 살아 있다.
        var expectedArrival: Date

        /// 남은 거리(m). 진행 바 계산에 쓴다.
        var remainingMeters: Int

        /// 출발 시점의 전체 거리(m).
        var totalMeters: Int

        /// **경로 위에서 여기까지 왔다(m).** 노선도의 점과 지도의 지나온/남은 색
        /// 분리가 이 값을 **함께** 쓴다.
        ///
        /// 예전에는 두 화면이 "얼마나 왔나" 를 각자 계산했다 — 노선도는
        /// `totalMeters - remainingMeters`, 지도는 좌표열에서 귀가자에게 가장 가까운
        /// 점. 정상 이동에서는 평균 36m 로 잘 맞았지만 예외에서 갈라졌다
        /// (2026-08-20 실측, 28.4km 경로): GPS 가 역행하면 7,404m, 경로를 1.5km
        /// 벗어나면 4,349m.
        ///
        /// **`remainingMeters` 를 되짚어서는 안 되는 이유가 그 이탈이다.** 서버는
        /// 경로를 벗어나면 그 값을 경로 따라 잰 것에서 **집까지 직선거리**로 바꾼다
        /// (`estimateSource == "offRoute"`). 직선은 경로보다 짧으니 되짚은 값이
        /// 커지고, 노선도의 점이 **앞으로 뛴다** — 실측에서 60% 지점에서 옆으로
        /// 빠졌는데 점이 85% 로 전진했다. 뜻이 바뀌는 값은 위치의 근거가 못 된다.
        ///
        /// 이 값은 서버의 `route_progress` 에서 나온다. 성질이 다르다 — 뒤로 가지
        /// 않고, 이탈하면 **갱신을 멈출 뿐** 뜻이 바뀌지 않는다. 경로 위에서만
        /// 정의된다.
        ///
        /// 자는 **정류장 거리와 같은 자**다(서버 `route_length()`, 좌표열을 따라
        /// 잰다). `totalMeters` 가 아니라 `RouteShape.totalMeters` 와 견줘야 한다 —
        /// 그쪽은 앱이 넣은 값이라 MapKit 자동차 거리에서 올 수 있다.
        ///
        /// nil 은 두 경우다. 경로 없이 시작한 귀가이거나, 이 필드를 모르는 서버가
        /// 보낸 갱신이거나. 그때는 두 화면이 예전 계산으로 돈다.
        var travelledMeters: Int?

        /// "지하철 · 풍산역까지 12분" 같은 한 줄 보조 문구.
        ///
        /// 저장된 경로로 도는 귀가면 서버가 지금 구간과 다음 지점까지 남은 시간을
        /// 여기에 담는다. 경로가 없으면 이동 수단만 들어간다.
        var detail: String?

        /// 저장된 경로 기준으로 밀린 시간(초). nil 이면 정시이거나 경로가 없다.
        ///
        /// 서버는 1분 미만을 보내지 않는다. 위치가 흔들리면 몇십 초는 늘 생기고,
        /// "지연 12초" 가 떴다 사라지면 화면이 고장 난 것처럼 보인다.
        var delaySeconds: Int?

        /// 이 값들이 **언제의 위치로** 만들어졌는지. 서버가 넣는다.
        ///
        /// **푸시를 받은 시각과 다르다.** 그 둘을 같다고 본 것이 2026-08-18 실주행에서
        /// 드러났다 — 갱신이 APNs 안에서 최대 27분 붙잡혀 있다가 내려왔고, 폰은 방금
        /// 받았으므로 "N분 전 확인" 문구가 뜨지 않았다. 화면은 27분 낡은 자리를
        /// 아무 표시 없이 지금 자리처럼 보여 줬다.
        ///
        /// 낡음의 기준은 배달 시각이 아니라 **측정 시각**이다. 그래서 상태 안에 싣는다.
        /// `aps.timestamp` 로는 안 된다 — ActivityKit 이 앱에 넘겨 주지 않는다.
        ///
        /// nil 은 이 필드를 모르는 서버가 보낸 것이다. 그때는 예전처럼 받은 시각으로
        /// 판단한다.
        var measuredAt: Date?

        /// 서버가 이 값들을 **어떻게** 냈는지. `"route"` 또는 `"distance"`.
        ///
        /// 앱은 자기가 저장된 경로로 시작했다는 것만 알고, 서버가 도중에 경로를
        /// 벗어나 직선거리 추정으로 되돌아간 것은 모른다. 2026-08-18 실주행에서
        /// 서버는 18:13 에 이탈했는데 앱 진단 화면은 끝까지 `저장된 경로 (실측)` 을
        /// 적고 있었다. 진단값이 거짓이면 진단을 방해한다.
        ///
        /// **열거형이 아니라 문자열이다.** `RouteShape.Stop.mode` 와 같은 이유다 —
        /// 서버가 새 낱말을 보내도 디코딩이 실패하지 않아야 한다. `ContentState`
        /// 디코딩이 한 번 실패하면 그 푸시는 통째로 버려지고 카드가 얼어붙는다.
        var estimateSource: String?

        // MARK: 지도

        /// 귀가자가 마지막으로 보고한 자리. nil 이면 아직 위치 보고가 없었거나,
        /// 이 필드를 모르는 서버가 보낸 갱신이다.
        ///
        /// **거리와 좌표는 다른 질문에 답한다.** `remainingMeters` 는 "얼마나
        /// 남았나" 에 답하지만 "어디쯤인가" 에는 답하지 못한다. 가족 화면의 지도가
        /// 이 두 값으로 점을 찍는다.
        var lat: Double?
        var lon: Double?

        /// 도착지 좌표. 지도에 집을 같이 찍어 거리감을 준다.
        ///
        /// 귀가 중에 바뀌지 않는 값이지만 고정값(`HomecomingAttributes`)이 아니라
        /// 갱신값에 있다. 고정값에 넣으면 push-to-start 경로까지 건드려야 하는데,
        /// 좌표 두 개로 얻는 것이 그만큼 되지 않는다.
        var homeLat: Double?
        var homeLon: Double?

        /// 도착 반경(m). 지도가 집 주위에 원으로 그린다.
        ///
        /// **판정에 쓰는 값과 같아야 한다.** 서버가 이 반경 안에 들어오면 단계를
        /// `nearby` 로 올린다. 화면에 다른 숫자를 그리면 "곧 도착" 이 왜 떴는지
        /// 설명하지 못한다.
        var homeRadius: Int?

        // MARK: 안전귀가

        /// 다음 안심 확인 마감 시각. nil 이면 안전귀가 모드가 아니다.
        ///
        /// 이 시각을 넘기도록 확인이 없으면 `anomaly` 가 `.unresponsive` 로 올라간다.
        var checkInDeadline: Date?

        /// 이 귀가가 **왜** 끝났는지.
        ///
        /// 도착과 공유 중지는 가족 화면에서 반드시 달라야 한다.
        /// 조용해진 이유를 모르면 안전귀가라고 할 수 없다.
        /// `stage` 로는 구분할 수 없다 — 중지는 진행이 아니라서 단계에 자리가 없다.
        var endReason: EndReason?

        /// 진행 단계와는 **다른 축**이다.
        ///
        /// `stage` 는 집에 가까워지는 정도라 뒤로 가지 않는다.
        /// 이상 상황은 그와 무관하게 떴다 사라진다 — 늦어지다 따라잡을 수도 있고,
        /// 도착 직전에 멈출 수도 있다. 한 축에 욱여넣으면 둘 다 망가진다.
        var anomaly: Anomaly?

        /// 다음에 탈 버스의 노선번호. 예: `"999"`.
        ///
        /// 셋(`busArrivalNo` · `busArrivalAt` · `busArrivalStops`)은 함께 오거나
        /// 함께 없다. 서버는 승차 15분 전부터만 싣는다.
        ///
        /// **없는 것이 기본이다.** 서울 시내버스는 공공데이터에 도착정보가 없어서
        /// 163번 구간에는 영영 안 온다(2026-08-26 실측: 국회의사당역 좌표로 정류장을
        /// 조회하면 빈 결과다). 화면은 그때 줄을 안 그린다 — 틀린 값을 그리는 것보다
        /// 안 그리는 것이 낫다.
        ///
        /// 서버가 조회를 배경으로 돌리므로 **첫 갱신에는 없고 그다음부터 있다.**
        /// 조회가 실측 9~13초인데 위치 보고 타임아웃이 8초라, 기다리게 두면
        /// 이 화면을 살려 주는 그 응답 자체가 끊긴다.
        var busArrivalNo: String?

        /// 그 버스가 정류장에 닿을 **절대시각**.
        ///
        /// **`몇 분 뒤` 가 아닌 이유가 이 앱의 갱신 방식이다.** 위치 보고를
        /// 일으키는 것은 시간이 아니라 150m 이동이고(`distanceFilter`), 정류장에
        /// 서서 기다리는 동안은 안 움직인다. 그동안 화면을 움직일 길은 푸시뿐인데
        /// 그게 늦으면 `10분 후` 가 8분 뒤에도 `10분 후` 다.
        ///
        /// 절대시각이면 시계가 알아서 흐른다. `expectedArrival` 이 이미 같은
        /// 이유로 절대시각이다.
        var busArrivalAt: Date?

        /// 그 버스가 몇 정류장 앞에 있는지. 모르면 nil.
        ///
        /// **이 값은 늙지 않는다.** `busArrivalAt` 은 절대시각이라 시계가 흐르면
        /// 스스로 맞아 가는데, `5정류장 전` 은 그대로 남아 거짓이 된다. 그래서
        /// `busArrivalMeasuredAt` 과 함께 봐야 하고, 낡으면 이 숫자만 감춘다.
        var busArrivalStops: Int?

        /// 도착정보를 **언제 쟀는지**. 정류장 수의 나이를 재는 데 쓴다.
        ///
        /// 2026-08-26 실측: 같은 버스가 15:36 에 5정류장, 15:37:55 에 3정류장 —
        /// 115초에 두 정류장, 약 57초에 하나다. 그래서 문턱을 60초로 둔다
        /// (`busArrivalStopsFresh`). 그만큼 지나면 숫자가 이미 하나 틀렸다고 본다.
        var busArrivalMeasuredAt: Date?

        /// **그다음 차**가 닿을 절대시각. 없으면 한 대뿐이거나 막차다.
        ///
        /// 앞차를 놓쳤을 때 얼마를 더 기다리는지가 뛸지 말지를 가른다 — 4분 뒤에
        /// 또 온다면 안 뛰어도 되고, 20분이면 뛰어야 한다. 실측에서 999번이
        /// 293초·1158초 두 대로 왔다(2026-08-26).
        var busArrivalThenAt: Date?

        /// 그다음 차가 몇 정류장 앞인지. `busArrivalStops` 와 같은 이유로 늙는다.
        var busArrivalThenStops: Int?
    }
}

// MARK: - RouteShape

extension HomecomingAttributes {

    /// 노선도에 그릴 정류장 목록.
    ///
    /// **좌표가 없다.** 노선도는 지리가 아니라 순서를 그린다 — 정류장 사이의 실제
    /// 방향이나 굽이는 여기에 담지 않는다.
    ///
    /// 예전에는 이 자리에 "위도·경도는 가족 폰으로 한 바이트도 가지 않는다" 고
    /// 적혀 있었다. 지금은 사실이 아니다 — 가족 화면의 지도가 `ContentState.lat`/
    /// `lon` 으로 귀가자의 자리를 찍는다. 노선도가 좌표를 안 쓴다는 것과, 좌표가
    /// 가족 폰에 가지 않는다는 것은 다른 말이다.
    ///
    /// 귀가 중에 안 바뀌므로 갱신값이 아니라 고정값이다. 서버가 `route_stops()`
    /// 로 접은 것을 그대로 받는다 — 앱이 다시 접으면 규칙이 두 벌이 되고,
    /// 어긋나면 귀가자와 가족이 다른 노선도를 본다.
    struct RouteShape: Codable, Hashable {

        struct Stop: Codable, Hashable {
            /// "풍산역"
            var name: String
            /// 여기까지 오는 수단. **경로가 쓰는 낱말 그대로**다 — `walk` / `bus`
            /// / `subway` / `car`. 갱신값의 `Transport` 와 별개이고 변환하지
            /// 않는다. 잇는 순간 노선도가 갱신값에 매인다.
            var mode: String
            /// 여기까지 오는 거리(m).
            var meters: Int
            /// 여기까지 걸리는 시간(초).
            var seconds: Int
            /// 여기서 갈아타며 기다리는 시간(초). 없으면 0.
            var waitSeconds: Int
        }

        var stops: [Stop]

        /// 정류장 거리의 합. **노선도의 분모는 이것이다.**
        ///
        /// `ContentState.totalMeters` 와 헷갈리면 안 된다. 그쪽은 액티비티를 시작한
        /// 앱이 넣은 값이라 저장된 경로가 아닌 다른 출처(MapKit 자동차 경로 등)에서
        /// 올 수 있다. 노선도는 정류장으로 그려지므로 정류장이 재는 자로만 재야
        /// 자기 안에서 앞뒤가 맞는다.
        var totalMeters: Int { stops.reduce(0) { $0 + $1.meters } }

        /// 노선도 위에서 지금 어디인가.
        ///
        /// `index` 는 향해 가는 중인 정류장, `fraction` 은 그 구간을 얼마나 왔나(0~1).
        /// 출발 직후면 (0, 0), 도착이면 (마지막, 1) 이다.
        struct Position: Equatable {
            var index: Int
            var fraction: Double
        }

        /// 지나온 거리(m)로 점의 자리를 낸다.
        ///
        /// **`progress` 를 바로 못 쓴다.** 진행률에 직선 노선도 길이를 곱하면
        /// 정류장과 어긋난다 — 구간마다 실제 길이가 크게 다르기 때문이다
        /// (도보 78m 와 지하철 18.7km 가 한 경로에 있다). 그래서 거리로 맞춘다.
        ///
        /// 정류장 거리의 합은 서버가 `totalMeters` 와 같게 만들어 준다
        /// (`route_stops()` 가 `leg_length()` 로 재는 이유). 그래도 여기서
        /// 양 끝을 잘라 둔다 — 위치가 튀어 남은거리가 음수로 오거나 총 거리를
        /// 넘어와도 점이 노선도 밖으로 나가면 안 된다.
        ///
        /// **선행조건: `stops` 는 비어 있으면 안 된다.** 빈 배열에는 애초에
        /// 유효한 인덱스가 없다 — `stops.isEmpty` 를 허용하면 `stops.count - 1`
        /// 이 -1 이 되어 뷰가 `stops[position.index]` 로 그대로 죽는다. 아래
        /// 가드는 그 -1 을 막고 index 0 을 대신 돌려주지만, 이는 "빈 배열에서도
        /// 안전한 값" 이 아니라 "그나마 덜 나쁜 값" 이다 — 정말 안전하려면
        /// 호출하는 쪽(뷰)이 `!stops.isEmpty` 를 먼저 확인해야 한다. 경로가
        /// 있는 귀가는 출발지에서 도착지까지 정류장이 최소 하나이므로 실제로는
        /// 일어나지 않아야 하는 입력이다.
        func position(travelled meters: Int) -> Position {
            guard !stops.isEmpty else { return Position(index: 0, fraction: 0) }
            var remaining = Double(max(0, meters))
            for (index, stop) in stops.enumerated() {
                let length = Double(stop.meters)
                // 길이 0 인 구간(제자리 이동)은 건너뛴다. 나누면 무한이 된다.
                if length <= 0 { continue }
                if remaining < length {
                    return Position(index: index, fraction: remaining / length)
                }
                remaining -= length
            }
            return Position(index: stops.count - 1, fraction: 1)
        }
    }
}

// MARK: - EndReason

extension HomecomingAttributes {

    enum EndReason: String, Codable, Hashable, CaseIterable {
        /// 집에 도착했다.
        case arrived
        /// 귀가자가 공유를 껐다. **도착이 아니다.**
        case stopped
    }
}

// MARK: - Audience

extension HomecomingAttributes {

    enum Audience: String, Codable, Hashable, CaseIterable {
        /// 귀가하는 본인. 공유가 돌고 있다는 확인과 안심 확인 버튼이 필요하다.
        case traveler
        /// 집에서 기다리는 가족. 어디까지 왔는지와 이상 상황이 필요하다.
        case watcher
    }
}

// MARK: - Anomaly

extension HomecomingAttributes {

    enum Anomaly: String, Codable, Hashable, CaseIterable {
        /// 도착 예정 시각을 여유 시간 이상 넘겼다.
        case delayed
        /// 한곳에 오래 멈춰 있다.
        case stalled
        /// 예상 경로에서 벗어났다. 경로 폴리라인이 필요해 서버가 판정한다.
        case offRoute
        /// 안심 확인 마감을 넘겼다.
        case unresponsive
        /// 위치가 한참 올라오지 않는다. 서버만 판단할 수 있다 —
        /// 기기 자신은 자기가 연락이 끊겼다는 걸 알 방법이 없다.
        case disconnected
    }
}

extension HomecomingAttributes.Anomaly {

    var title: String {
        switch self {
        case .delayed:      return "예정보다 늦어요"
        case .stalled:      return "한곳에 머물러 있어요"
        case .offRoute:     return "경로를 벗어났어요"
        case .unresponsive: return "확인이 없어요"
        case .disconnected: return "연락이 닿지 않아요"
        }
    }

    var shortLabel: String {
        switch self {
        case .delayed:      return "지연"
        case .stalled:      return "정지"
        case .offRoute:     return "이탈"
        case .unresponsive: return "무응답"
        case .disconnected: return "두절"
        }
    }

    var symbolName: String {
        switch self {
        case .delayed:      return "clock.badge.exclamationmark.fill"
        case .stalled:      return "pause.circle.fill"
        case .offRoute:     return "arrow.triangle.branch"
        case .unresponsive: return "exclamationmark.triangle.fill"
        case .disconnected: return "wifi.slash"
        }
    }

    /// 보호자 화면을 깨울 만한 수준인지.
    var isUrgent: Bool {
        switch self {
        case .unresponsive, .offRoute, .disconnected: return true
        case .delayed, .stalled:       return false
        }
    }

    var tint: Color {
        isUrgent
            ? Color(red: 1.00, green: 0.35, blue: 0.35)   // 빨강
            : Color(red: 1.00, green: 0.67, blue: 0.24)   // 주황
    }

    /// 동시에 여러 개가 성립하면 심각한 쪽만 보여 준다. 작을수록 우선.
    var priority: Int {
        switch self {
        case .disconnected: return 0
        case .unresponsive: return 1
        case .offRoute:     return 2
        case .stalled:      return 3
        case .delayed:      return 4
        }
    }
}

// MARK: - Stage

extension HomecomingAttributes {

    enum Stage: String, Codable, Hashable, CaseIterable {
        /// 귀가 시작을 눌러 막 출발한 상태.
        case leaving
        /// 이동 중.
        case moving
        /// 도착 임박 (남은 거리가 임계값 이하).
        case nearby
        /// 도착 완료.
        case arrived
    }
}

extension HomecomingAttributes.Stage {

    /// 가족이 보는 한 줄 헤드라인.
    func headline(for name: String) -> String {
        switch self {
        case .leaving: return "\(name) 출발했어요"
        case .moving:  return "\(name) 집으로 가는 중"
        case .nearby:  return "\(name) 곧 도착해요"
        case .arrived: return "\(name) 도착했어요"
        }
    }

    /// 축소 상태(minimal/compact)에서 쓰는 아주 짧은 라벨.
    var shortLabel: String {
        switch self {
        case .leaving: return "출발"
        case .moving:  return "이동 중"
        case .nearby:  return "곧 도착"
        case .arrived: return "도착"
        }
    }

    var tint: Color {
        switch self {
        case .leaving: return Color(red: 0.36, green: 0.62, blue: 1.00)   // 파랑
        case .moving:  return Color(red: 0.36, green: 0.62, blue: 1.00)
        case .nearby:  return Color(red: 1.00, green: 0.67, blue: 0.24)   // 주황
        case .arrived: return Color(red: 0.32, green: 0.83, blue: 0.53)   // 초록
        }
    }

    var isFinished: Bool { self == .arrived }
}

// MARK: - Transport

extension HomecomingAttributes {

    enum Transport: String, Codable, Hashable, CaseIterable {
        case subway
        case bus
        case car
        case walk

        var symbolName: String {
            switch self {
            case .subway: return "tram.fill"
            case .bus:    return "bus.fill"
            case .car:    return "car.fill"
            case .walk:   return "figure.walk"
            }
        }

        var title: String {
            switch self {
            case .subway: return "지하철"
            case .bus:    return "버스"
            case .car:    return "차량"
            case .walk:   return "도보"
            }
        }
    }
}

// MARK: - 와이어 형식

// 서버가 푸시로 밀어 넣는 `content-state` 가 이 타입으로 곧장 디코딩된다.
// 중간에 우리 코드가 검사할 기회가 없으므로, 기본 Codable 에 맡기지 않고 형식을 못박는다.
//
// 특히 날짜: Swift 기본 구현은 2001-01-01 기준 초라는 숫자를 쓴다.
// 서버가 Unix epoch 를 넣어도 타입이 맞아 에러 없이 통과하고 값만 어긋난다.
// ISO8601 문자열이면 와이어 위에서 사람이 읽을 수 있어 그런 착오가 생기지 않는다.

extension HomecomingAttributes.ContentState {

    // **여기 빠진 필드는 서버가 보내도 화면에 닿지 않는다.**
    //
    // `init(from:)` 이 손으로 쓴 것이라, 목록에 없는 필드는 조용히 nil 로 남는다.
    // 컴파일도 되고 푸시도 성공하고 에러도 없다 — 값만 사라진다. `delaySeconds` 가
    // 그렇게 빠져 있었다: 서버는 2026-08-18 실주행 내내 6~8분 지연을 실어 보냈는데
    // 배지("10분 지연")가 한 번도 뜨지 않았다.
    //
    // **`ContentState` 에 필드를 더하면 이 목록과 아래 두 함수도 같이 고쳐라.**
    enum CodingKeys: String, CodingKey {
        case stage
        case transport
        case expectedArrival
        case remainingMeters
        case totalMeters
        case travelledMeters
        case detail
        case delaySeconds
        case measuredAt
        case estimateSource
        case lat
        case lon
        case homeLat
        case homeLon
        case homeRadius
        case checkInDeadline
        case anomaly
        case endReason
        case busArrivalNo
        case busArrivalAt
        case busArrivalStops
        case busArrivalMeasuredAt
        case busArrivalThenAt
        case busArrivalThenStops
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stage = try container.decode(HomecomingAttributes.Stage.self, forKey: .stage)
        transport = try container.decode(HomecomingAttributes.Transport.self, forKey: .transport)
        expectedArrival = try container.decodeWireDate(forKey: .expectedArrival)
        remainingMeters = try container.decode(Int.self, forKey: .remainingMeters)
        totalMeters = try container.decode(Int.self, forKey: .totalMeters)
        travelledMeters = try container.decodeIfPresent(Int.self, forKey: .travelledMeters)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        delaySeconds = try container.decodeIfPresent(Int.self, forKey: .delaySeconds)
        measuredAt = try container.decodeWireDateIfPresent(forKey: .measuredAt)
        estimateSource = try container.decodeIfPresent(String.self, forKey: .estimateSource)
        lat = try container.decodeIfPresent(Double.self, forKey: .lat)
        lon = try container.decodeIfPresent(Double.self, forKey: .lon)
        homeLat = try container.decodeIfPresent(Double.self, forKey: .homeLat)
        homeLon = try container.decodeIfPresent(Double.self, forKey: .homeLon)
        homeRadius = try container.decodeIfPresent(Int.self, forKey: .homeRadius)
        checkInDeadline = try container.decodeWireDateIfPresent(forKey: .checkInDeadline)
        anomaly = try container.decodeIfPresent(HomecomingAttributes.Anomaly.self, forKey: .anomaly)
        endReason = try container.decodeIfPresent(HomecomingAttributes.EndReason.self, forKey: .endReason)
        busArrivalNo = try container.decodeIfPresent(String.self, forKey: .busArrivalNo)
        busArrivalAt = try container.decodeWireDateIfPresent(forKey: .busArrivalAt)
        busArrivalStops = try container.decodeIfPresent(Int.self, forKey: .busArrivalStops)
        busArrivalMeasuredAt = try container.decodeWireDateIfPresent(forKey: .busArrivalMeasuredAt)
        busArrivalThenAt = try container.decodeWireDateIfPresent(forKey: .busArrivalThenAt)
        busArrivalThenStops = try container.decodeIfPresent(Int.self, forKey: .busArrivalThenStops)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stage, forKey: .stage)
        try container.encode(transport, forKey: .transport)
        try container.encodeWire(expectedArrival, forKey: .expectedArrival)
        try container.encode(remainingMeters, forKey: .remainingMeters)
        try container.encode(totalMeters, forKey: .totalMeters)
        try container.encodeIfPresent(travelledMeters, forKey: .travelledMeters)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(delaySeconds, forKey: .delaySeconds)
        try container.encodeWireIfPresent(measuredAt, forKey: .measuredAt)
        try container.encodeIfPresent(estimateSource, forKey: .estimateSource)
        try container.encodeIfPresent(lat, forKey: .lat)
        try container.encodeIfPresent(lon, forKey: .lon)
        try container.encodeIfPresent(homeLat, forKey: .homeLat)
        try container.encodeIfPresent(homeLon, forKey: .homeLon)
        try container.encodeIfPresent(homeRadius, forKey: .homeRadius)
        try container.encodeWireIfPresent(checkInDeadline, forKey: .checkInDeadline)
        try container.encodeIfPresent(anomaly, forKey: .anomaly)
        try container.encodeIfPresent(endReason, forKey: .endReason)
        try container.encodeIfPresent(busArrivalNo, forKey: .busArrivalNo)
        try container.encodeWireIfPresent(busArrivalAt, forKey: .busArrivalAt)
        try container.encodeIfPresent(busArrivalStops, forKey: .busArrivalStops)
        try container.encodeWireIfPresent(busArrivalMeasuredAt, forKey: .busArrivalMeasuredAt)
        try container.encodeWireIfPresent(busArrivalThenAt, forKey: .busArrivalThenAt)
        try container.encodeIfPresent(busArrivalThenStops, forKey: .busArrivalThenStops)
    }
}

extension HomecomingAttributes {

    enum CodingKeys: String, CodingKey {
        case travelerName
        case destinationName
        case departedAt
        case audience
        case sessionId
        case routeShape
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        travelerName = try container.decode(String.self, forKey: .travelerName)
        destinationName = try container.decode(String.self, forKey: .destinationName)
        departedAt = try container.decodeWireDate(forKey: .departedAt)
        audience = try container.decodeIfPresent(Audience.self, forKey: .audience) ?? .traveler
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionId)
        routeShape = try container.decodeIfPresent(RouteShape.self, forKey: .routeShape)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(travelerName, forKey: .travelerName)
        try container.encode(destinationName, forKey: .destinationName)
        try container.encodeWire(departedAt, forKey: .departedAt)
        try container.encode(audience, forKey: .audience)
        try container.encodeIfPresent(sessionID, forKey: .sessionId)
        try container.encodeIfPresent(routeShape, forKey: .routeShape)
    }
}

// MARK: - ContentState 파생 값

extension HomecomingAttributes.ContentState {

    /// 0.0 ~ 1.0 진행률. 도착 단계면 항상 1.0.
    var progress: Double {
        guard stage != .arrived else { return 1 }
        guard totalMeters > 0 else { return 0 }
        let done = Double(totalMeters - remainingMeters) / Double(totalMeters)
        return min(max(done, 0), 1)
    }

    /// 남은 거리를 사람이 읽는 문자열로. 1km 미만은 m, 이상은 소수 한 자리 km.
    var remainingDistanceText: String {
        if remainingMeters < 1_000 {
            let rounded = max(0, (remainingMeters / 10) * 10)
            return "\(rounded)m"
        }
        return String(format: "%.1fkm", Double(remainingMeters) / 1_000)
    }

    /// 도착 예정 시각 (예: "19:24").
    var arrivalClockText: String {
        Self.clockFormatter.string(from: expectedArrival)
    }

    /// 시각 뒤에 붙는 말까지 붙인 한 줄. **`도착` 만 적으면 안 된다.**
    ///
    /// 가는 중에 `18:30 도착` 이라고 적혀 있으면 "18:30에 도착 예정" 이 아니라
    /// **"18:30에 도착했다"** 로 읽힌다. 2026-08-25 실주행에서 가족이 그렇게 읽고
    /// 도착한 줄 알았다 — 그때 서버는 `moving · 3126m` 을 밀고 있었고 실제 도착은
    /// 18:48 이었다.
    ///
    /// **도착한 뒤에는 `예정` 을 떼야 한다.** 그때는 이 값이 예정이 아니라 실제로
    /// 닿은 시각이기 때문이다(도착 처리에서 `expectedArrival` 이 그 시각으로 바뀐다).
    ///
    /// 카드·잠금화면·아일랜드가 이 한 줄을 같이 쓴다. 세 화면이 같은 값을 다르게
    /// 적으면 "가족에게 이렇게 보인다" 는 확인이 거짓말이 된다.
    var arrivalClockLine: String {
        "\(arrivalClockText) \(stage.isFinished ? "도착" : "도착 예정")"
    }

    /// 다음에 탈 버스의 도착 한 줄. "999번 18:42 도착 · 6정류장 전"
    ///
    /// **노선도와 잠금화면이 이 하나를 같이 쓴다.** 두 화면이 같은 값을 다르게
    /// 적으면 어느 쪽이 참인지 알 수 없다 — `arrivalClockLine` 이 같은 이유로
    /// 여기 있다.
    ///
    /// **시각으로 적는다.** 남은 분으로 적으면 갱신이 끊긴 동안 그 글자가 멈춘다.
    /// 정류장에서 기다리는 동안이 정확히 그 상황이고, 하필 그때 이 값이 가장
    /// 필요하다. 근거는 `busArrivalAt` 주석에 있다.
    ///
    /// 값이 없으면 nil 이고 두 화면 다 줄을 안 그린다.
    var busArrivalLine: String? {
        guard let clock = busArrivalClockText, let no = busArrivalNo else { return nil }
        var line = "\(no)번 \(clock) 도착"
        if let stops = busArrivalStopsText { line += " · \(stops)" }
        if let then = busArrivalThenClockText { line += " · 다음 \(then)" }
        return line
    }

    /// 버스가 닿을 시각만. "15:44"
    var busArrivalClockText: String? {
        busArrivalAt.map { Self.clockFormatter.string(from: $0) }
    }

    /// 정류장 수가 아직 참인가. **잰 지 60초 안쪽일 때만 참으로 본다.**
    ///
    /// 근거는 `busArrivalMeasuredAt` 주석에 있다 — 실측에서 약 57초에 한 정류장씩
    /// 줄었다. 잰 시각을 모르는 서버가 보낸 갱신이면(옛 서버) 판단할 수 없으니
    /// 그리지 않는다. 모르는 것을 그럴듯하게 그리지 않는다.
    var busArrivalStopsFresh: Bool {
        guard let measured = busArrivalMeasuredAt else { return false }
        return Date().timeIntervalSince(measured) < 60
    }

    /// "2정류장 전". 낡았거나 모르면 nil.
    var busArrivalStopsText: String? {
        guard busArrivalStopsFresh, let stops = busArrivalStops, stops > 0 else { return nil }
        return "\(stops)정류장 전"
    }

    /// 그다음 차의 시각만. "16:14"
    var busArrivalThenClockText: String? {
        busArrivalThenAt.map { Self.clockFormatter.string(from: $0) }
    }

    /// 그다음 차의 "11정류장 전". 낡았거나 모르면 nil.
    var busArrivalThenStopsText: String? {
        guard busArrivalStopsFresh, let stops = busArrivalThenStops, stops > 0 else { return nil }
        return "\(stops)정류장 전"
    }

    /// "16:14 · 11정류장 전". 한 줄로 쓰는 자리(잠금화면)용. 없으면 nil.
    var busArrivalThenText: String? {
        guard let clock = busArrivalThenClockText else { return nil }
        guard let stops = busArrivalThenStopsText else { return clock }
        return "\(clock) · \(stops)"
    }

    /// 도착예정이 이미 지났다. **그리는 그 순간의 판정이다.**
    var isOverdue: Bool { expectedArrival <= Date() }


    /// 저장된 경로보다 밀린 시간 (예: "3분 지연"). 정시면 nil.
    ///
    /// 서버가 1분 미만은 보내지 않는다. 여기서도 분 단위로만 말한다 —
    /// "지연 97초" 같은 숫자는 기다리는 사람에게 아무 뜻이 없다.
    var delayText: String? {
        guard let delaySeconds, delaySeconds >= 60 else { return nil }
        return "\(delaySeconds / 60)분 지연"
    }

    /// 한 줄 보조 문구에 지연을 붙인 것. 지연이 없으면 문구만.
    ///
    /// 지연을 따로 놓지 않고 문구 뒤에 붙이는 이유는 잠금화면 한 줄이 전부라서다.
    /// 도착예정이 왜 밀렸는지가 그 한 줄에서 설명돼야 한다.
    var detailWithDelay: String? {
        guard let detail, !detail.isEmpty else { return delayText }
        guard let delayText else { return detail }
        return "\(detail) · \(delayText)"
    }

    /// 남은 시간(분). 카운트다운을 쓸 수 없는 자리(위젯 프리뷰 등)에서 폴백으로 쓴다.
    var remainingMinutes: Int {
        max(0, Int(ceil(expectedArrival.timeIntervalSinceNow / 60)))
    }

    /// `Text(timerInterval:)` 에 넘길 범위. 이미 지난 시각이면 0초 범위로 접는다.
    ///
    /// **시스템이 이 범위를 굴리면서 0:00 에서 멈춘다 — 위로 올라가지 않는다.**
    /// 갱신이 한 건도 안 와도 그렇다. `CountdownText` 가 이 성질을 쓴다. 이유는
    /// 그쪽 주석에 있다.
    ///
    /// 접어 두는 것이 중요하다. `Date()...expectedArrival` 을 그냥 만들면 지난
    /// 시각일 때 하한이 상한보다 커서 죽는다.
    var countdownRange: ClosedRange<Date> {
        Self.range(to: expectedArrival)
    }

    /// 남은 시간을 `1:21` 처럼 시:분으로. 축소 아일랜드가 쓴다.
    ///
    /// **시스템 타이머가 이 형식을 못 만든다.** `Text(timerInterval:)` 은
    /// `H:MM:SS` 아니면 `MM:SS` 뿐이라 초를 뗄 수 없다. 그래서 직접 그린다.
    ///
    /// 같은 타이머를 두 번 그려 하나는 앞을, 하나는 뒤를 잘라 붙이는 방법을 실기기에서
    /// 시험했고 **안 됐다.** `.frame(width:)` + `.clipped()` 로는 기하학적으로 안
    /// 잘린다 — 시스템 타이머 텍스트는 프레임 안에서 스스로 줄임표를 넣거나 줄바꿈해서
    /// `1:…` 과 두 줄짜리 `81` 이 나왔다. 그러니 이 형식을 원하면 직접 그리는 수밖에
    /// 없고, 얼어붙는 대가를 받아들여야 한다.
    ///
    /// **초를 보여 주는 쪽으로 바꿔 봤고 되돌렸다** (2026-08-19, 실기기).
    /// `Text(timerInterval:)` 로 두면 시스템이 초를 굴려 주고 오독도 없어지는데,
    /// `1:21:47` 일곱 글자에 알약이 벌어지는 걸 못 참았다. 근거는
    /// `docs/LIVE-ACTIVITY.md` 의 "시스템 타이머로 바꿔 봤고 되돌렸다" 에 있다.
    ///
    /// 대가를 알고 쓴다 — 갱신이 올 때만 바뀐다. heartbeat 가 2분마다 밀어 주니
    /// 평소에는 최대 2분 뒤처지고, 진짜 신호가 끊기면 그동안 얼어붙는다. 잠금화면
    /// 카운트다운은 시스템이 굴리므로 그때 둘이 어긋난다.
    /// **늦으면 `0:00` 이 아니라 `+11` 이다.**
    ///
    /// 예전에는 `max(0, ...)` 로 눌렀다. 그래서 2026-08-18 실주행 18:51 부터 도착
    /// (19:02)까지 **11분 동안 축소 아일랜드가 `0:00`** 이었다. `0:00` 은 "지금
    /// 도착한다" 로 읽히는데 실제로는 11분 늦고 있었다. 눌러 놓은 값은 틀린 값이다.
    ///
    /// `+` 를 붙여 세 글자로 둔다. `1:21` 이 네 글자니 알약이 벌어지지 않는다 —
    /// 폭이 벌어지는 게 제일 싫다고 정한 그 결정을 그대로 지킨다. `-0:11` 은 다섯
    /// 글자라 안 된다. 몇 분 늦었는지 자세히는 확장 화면과 잠금화면에 있다.
    ///
    /// **알고 미룬 것 — 한 시간 아래에서 이 형식은 오독된다.**
    ///
    /// 시:분이라 27분이 `0:27` 로 나오는데, 사람은 콜론을 보면 분:초로 읽어서 이걸
    /// **27초**로 읽는다. 2026-08-19 실기기에서 확인했다. 자릿수가 60배 틀린다.
    /// `1:21` 은 한 시간 넘는 경우만 놓고 정한 형식이었고, 그 아래를 못 봤다.
    ///
    /// 고치려면 콜론의 뜻을 하나로 둬야 한다 — 콜론이 있으면 항상 시:분, 없으면
    /// 항상 분(`27분` / `1:20`). 네 글자를 넘지 않고 폭도 안 넓어진다.
    ///
    /// **한 시간 아래를 `27:00`(분:초)으로 두는 것은 답이 아니다.** 오독이 반대쪽으로
    /// 옮겨갈 뿐이다 — 분:초에 익숙해진 눈이 `1:20` 을 1분 20초로 읽는다. 그리고 이
    /// 이 귀가는 82분이라 **매번 처음 22분이 그 구간**이다. 내려가는 모습도 `1:00` 다음이
    /// `59:59` 로 숫자가 커진다.
    ///
    /// 지금은 그대로 둔다(사용자 결정). 고칠 때 위 근거에서 다시 시작하면 된다.
    var remainingClockText: String {
        let seconds = Int(expectedArrival.timeIntervalSinceNow)
        if seconds < 0 {
            // 두 자리로 묶는다. 세 자리가 되면 알약이 벌어진다.
            return "+\(min(99, (-seconds) / 60))"
        }
        return String(format: "%d:%02d", seconds / 3600, (seconds % 3600) / 60)
    }

    // MARK: 안전귀가

    /// 안전귀가 모드로 도는 중인지.
    var isSafetyMode: Bool { checkInDeadline != nil }

    /// 확인 마감까지의 카운트다운 범위.
    var checkInRange: ClosedRange<Date>? {
        checkInDeadline.map { Self.range(to: $0) }
    }

    /// 귀가자가 공유를 껐다. 도착과 혼동되면 안 되는 상태.
    var isStopped: Bool { endReason == .stopped }

    /// 화면 색. 이상 상황이 있으면 그쪽이 이긴다 — 그게 지금 봐야 할 정보이므로.
    var tint: Color {
        // 중지는 회색이다. 초록(도착)으로 보이면 안 되고, 빨강(이상)도 아니다.
        if isStopped { return Color(red: 0.62, green: 0.64, blue: 0.68) }
        return anomaly?.tint ?? stage.tint
    }

    /// 한 줄 헤드라인. 도착하지 않은 상태에서 이상이 있으면 그것부터 말한다.
    func headline(for name: String) -> String {
        if isStopped { return "\(name) 공유를 껐어요" }
        if let anomaly, !stage.isFinished { return "\(name) · \(anomaly.title)" }
        return stage.headline(for: name)
    }

    /// "정보가 오래됐어요" 로 흐려질 시점.
    ///
    /// 안전귀가 모드에서는 확인 마감을 넘기는 순간이 그 시점이다.
    /// **앱 코드가 한 줄도 돌지 않아도** 시스템이 알아서 화면을 흐리게 만들어 준다 —
    /// 무응답은 정의상 아무 일도 일어나지 않을 때 성립하므로, 이 시스템 장치가 중요하다.
    var staleDate: Date {
        let arrivalStale = expectedArrival.addingTimeInterval(10 * 60)
        guard let checkInDeadline else { return arrivalStale }
        return min(checkInDeadline, arrivalStale)
    }

    /// 확인 마감이 코앞이라 축소 화면에서도 알려야 하는 상태인지.
    func checkInIsPressing(within seconds: TimeInterval = 3 * 60) -> Bool {
        guard let checkInDeadline, !stage.isFinished else { return false }
        return checkInDeadline.timeIntervalSinceNow <= seconds
    }

    private static func range(to date: Date) -> ClosedRange<Date> {
        let now = Date()
        return now...max(date, now)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - 프리뷰용 샘플

extension HomecomingAttributes {

    /// 가족이 보는 화면.
    static var preview: HomecomingAttributes {
        HomecomingAttributes(
            travelerName: "아빠",
            destinationName: "집",
            departedAt: Date().addingTimeInterval(-12 * 60),
            audience: .watcher
        )
    }

    /// 귀가자 본인이 보는 화면.
    static var previewTraveler: HomecomingAttributes {
        var attributes = preview
        attributes.audience = .traveler
        return attributes
    }
}

extension HomecomingAttributes.ContentState {

    static var moving: Self {
        .init(
            stage: .moving,
            transport: .subway,
            expectedArrival: Date().addingTimeInterval(12 * 60),
            remainingMeters: 4_200,
            totalMeters: 11_000,
            detail: "2호선 · 3정거장 남음"
        )
    }

    static var nearby: Self {
        .init(
            stage: .nearby,
            transport: .walk,
            expectedArrival: Date().addingTimeInterval(3 * 60),
            remainingMeters: 240,
            totalMeters: 11_000,
            detail: "아파트 정문 앞"
        )
    }

    /// 안전귀가 모드 · 정상 이동 중.
    static var safetyMoving: Self {
        var state = moving
        state.checkInDeadline = Date().addingTimeInterval(11 * 60)
        return state
    }

    /// 확인 마감이 코앞.
    static var checkInDue: Self {
        var state = moving
        state.checkInDeadline = Date().addingTimeInterval(90)
        return state
    }

    /// 확인 마감을 넘겼다.
    static var unresponsive: Self {
        var state = moving
        state.checkInDeadline = Date().addingTimeInterval(-3 * 60)
        state.anomaly = .unresponsive
        return state
    }

    /// 한곳에 멈춰 있다.
    static var stalled: Self {
        var state = moving
        state.checkInDeadline = Date().addingTimeInterval(6 * 60)
        state.anomaly = .stalled
        state.detail = "역삼역 3번 출구 인근"
        return state
    }

    static var arrived: Self {
        .init(
            stage: .arrived,
            transport: .walk,
            expectedArrival: Date(),
            remainingMeters: 0,
            totalMeters: 11_000,
            detail: nil
        )
    }
}

extension String {

    /// 이름 뒤에 붙는 조사를 고른다. **받침이 있으면 `이`, 없으면 `가`.**
    ///
    /// `"\(name)이 도착했어요"` 로 박아 두었더니 알림이 `아빠이 집에 도착했어요` 로
    /// 떴다(2026-08-25). 이름은 사용자가 적는 값이라 받침이 있는지 미리 알 수 없다.
    ///
    /// 서버의 `은는이가()` 와 **같은 규칙이다** — 같은 문장을 서버가 만들 때도 있고
    /// (가족 폰 알림) 앱이 만들 때도 있어서(귀가자 폰 알림), 두 곳이 갈리면 같은
    /// 사건이 기기마다 다른 문장으로 뜬다.
    ///
    /// 한글 음절만 정확히 가른다 — `(코드 - 0xAC00) % 28` 이 0 이 아니면 받침이 있다.
    /// 한글이 아닌 끝글자(영문·숫자·기호)는 받침 없음으로 본다.
    var 이가: String {
        guard let last = trimmingCharacters(in: .whitespaces).unicodeScalars.last,
              (0xAC00...0xD7A3).contains(last.value)
        else { return self + "가" }
        return self + ((last.value - 0xAC00) % 28 == 0 ? "가" : "이")
    }
}
