import SwiftUI

// 위젯과 앱이 함께 쓰는 화면 조각.
//
// 가족은 잠금화면에서도 보고 앱에서도 본다. 같은 값을 다르게 그리면
// 어느 쪽이 맞는지 알 수 없으므로 그리는 코드를 하나로 둔다.

/// 이동 수단 아이콘을 상태 색으로 물들여 감싼 원형 배지.
/// 이상 상황이 있으면 이동 수단 대신 경고 아이콘이 들어간다 — 지금 봐야 할 건 그쪽이다.
struct TransportBadge: View {
    let state: HomecomingAttributes.ContentState
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle()
                .fill(state.tint.opacity(0.18))
            Image(systemName: symbolName)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(state.tint)
        }
        .frame(width: size, height: size)
    }

    private var symbolName: String {
        if state.isStopped { return "eye.slash.fill" }
        if let anomaly = state.anomaly, !state.stage.isFinished { return anomaly.symbolName }
        return state.stage.isFinished ? "house.fill" : state.transport.symbolName
    }
}

/// 출발점에서 집까지의 진행 바. 현재 위치는 진행률 지점에 찍힌 점으로 표시한다.
struct HomecomingProgressBar: View {
    let state: HomecomingAttributes.ContentState
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = width * state.progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.14))
                    .frame(height: height)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [state.tint.opacity(0.55), state.tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(height, x), height: height)

                Circle()
                    .fill(.white)
                    .frame(width: height + 5, height: height + 5)
                    .shadow(color: state.tint.opacity(0.8), radius: 3)
                    .offset(x: min(max(0, x - (height + 5) / 2), width - (height + 5)))
            }
            .frame(height: geo.size.height, alignment: .center)
        }
        .frame(height: height + 5)
    }
}

/// 경로의 정류장을 세로로 잇고 그 위에 지금 자리를 찍는다.
///
/// **지도가 아니라 노선도다.** 우리가 아는 건 정류장이고 그 사이는 직선이다.
/// 지도는 "이게 정확한 위치" 라고 말하는 매체라 부정확한 선을 올리면 거짓말이
/// 된다. 노선도는 순서와 남은 개수만 말하겠다고 선언하는 매체다.
///
/// `HomecomingProgressBar` 를 대신한다. 같은 값을 쓰되 정류장 이름을 붙여 준다.
struct RouteStripView: View {

    let shape: HomecomingAttributes.RouteShape
    let state: HomecomingAttributes.ContentState
    /// 마지막으로 위치가 확인된 때. **`state.measuredAt` 이 없을 때만 쓰는 대체값**
    /// 이다 — 이유는 `hereNote` 주석에 있다. nil 이면 "언제 것인지" 를 적지 않는다.
    var lastFixedAt: Date? = nil

    /// 버스 도착을 다시 물어 오는 일. **nil 이면 새로고침 버튼을 그리지 않는다.**
    ///
    /// 귀가자 카드만 넘긴다. 가족은 남의 세션을 새로 조회할 수 없고, 버튼을 그려
    /// 놓고 아무 일도 안 나는 것이 없는 것보다 나쁘다.
    var onRefreshBusArrival: (() async -> Void)? = nil

    @State private var refreshing = false

    /// 노선도 위의 지금 자리.
    ///
    /// **지나온 거리는 서버가 준다.** `state.travelledMeters` 다. 지도의 지나온/남은
    /// 색 분리도 같은 값을 쓰므로 두 화면이 어긋날 수 없다 — 예전에는 각자 계산해서
    /// 예외 상황에서 갈라졌다(2026-08-20 실측: GPS 역행 7,404m, 이탈 4,349m).
    ///
    /// **남은거리로 되짚는 것은 폴백일 뿐이다.** 그 계산은 이탈하면 틀린다 — 서버가
    /// `remainingMeters` 를 집까지 직선거리로 바꾸므로 되짚은 값이 커지고 점이 앞으로
    /// 뛴다. 그래서 옛 서버(이 필드를 안 보내는)에서만 쓴다. 자세한 근거는
    /// `ContentState.travelledMeters` 주석에 있다.
    ///
    /// **분모는 `state.totalMeters` 가 아니라 정류장 거리의 합이다.**
    /// 둘은 다른 자로 잰 값이다. 정류장 거리는 서버가 경로 좌표열을 따라 쟀고,
    /// `totalMeters` 는 액티비티를 시작한 앱이 넣은 값이라 저장된 경로가 아니라
    /// MapKit 자동차 경로에서 올 수 있다.
    ///
    /// 2026-08-14 실주행에서 실제로 어긋났다. 집에 도착해 남은거리가 0 인데도
    /// **흰 점이 마지막 구간 맨 위에 멈춰 있었다** — 분모(자동차 거리)가 분자
    /// (정류장 합)보다 짧아 아무리 가도 끝에 닿지 못했다.
    ///
    /// 정류장 합을 쓰면 노선도가 자기 값만으로 자기를 그린다. 남은거리가 0 이면
    /// 점은 반드시 마지막 정류장에 닿는다.
    private var position: HomecomingAttributes.RouteShape.Position {
        // 도착하면 남은거리가 정확히 0 이 아니어도 끝에 세운다. 도착 판정의 주인은
        // 서버의 `stage` 이지 거리가 아니다 — 도착 반경 안에서 GPS 가 흔들려도
        // 점이 집에서 떨어져 나가면 안 된다.
        if state.stage.isFinished {
            return .init(index: max(0, shape.stops.count - 1), fraction: 1)
        }
        // 옛 서버는 진행도를 안 보낸다. 그때만 예전처럼 남은거리로 되짚는다.
        return shape.position(
            travelled: state.travelledMeters ?? (shape.totalMeters - state.remainingMeters))
    }

    // MARK: - 자리 세기
    //
    // **행 번호와 정류장 번호가 다르다.** 맨 위에 이름 없는 출발점 행이 하나 있다.
    //
    //     행 0        출발점          ← stops 에 없다
    //     이음 0                     ← stops[0] 으로 가는 구간
    //     행 1        stops[0]
    //     이음 1                     ← stops[1] 로 가는 구간
    //     행 2        stops[1]
    //     ...
    //
    // **출발점 행이 없으면 첫 구간에 점을 놓을 자리가 없다.** 출발한 지 3분이면
    // 아직 첫 정류장에 안 왔는데, 점을 정류장 행에 찍으면 도착한 것처럼 보인다.
    // **점은 행이 아니라 이음 위에 있다.** 그래서 `stopRow` 는 지났는지만 말하고,
    // 지금 자리를 실제로 찍는 건 `connector` 다.

    /// 세로 줄의 왼쪽 칸(점·선) 너비. `stopRow` · `connector` 두 행 종류가
    /// 이 값을 공유해야 세로 줄이 어긋나지 않는다 — 하나만 고치면 나머지가 계단처럼 밀린다.
    private let railColumnWidth: CGFloat = 12

    /// 지금까지 지난 행의 마지막 번호. 보통 `position.index` 다 — 그 행(`stops[index]`)
    /// 으로 아직 향해 가는 중이니까. 그런데 도착하면(`fraction` 이 1) 향해 가던
    /// 정류장에 이미 닿은 것이므로 그 행까지 지난 걸로 쳐야 한다 — 안 그러면 점은
    /// 마지막 이음의 맨 아래까지 내려왔는데 집만 안 지난 것처럼 흐리게 남는다.
    /// `RouteShape.position` 구현상 `fraction` 이 1이 되는 경우는 오직 마지막
    /// 정류장에 닿았을 때뿐이라(중간 구간은 항상 1 미만), 이 보정이 중간 구간
    /// 판정에는 영향을 주지 않는다.
    private var passedThroughRow: Int {
        position.fraction >= 1 ? position.index + 1 : position.index
    }

    // 행을 접지 않는다. 정류장이 많아도 전부 그린다 — 다음 세 가지가 접을
    // 근거를 없앤다.
    // 1. 이 뷰를 담는 `ContentView` 본문이 이미 통째로 `ScrollView` 안이다.
    //    노선도가 길어지면 페이지가 길어질 뿐이라, 접지 않아도 중첩 스크롤
    //    문제가 생기지 않는다.
    // 2. 이 뷰는 잠금화면·다이내믹 아일랜드에 안 쓰인다(그쪽은 `CountdownText`
    //    처럼 한 줄짜리 값만 쓴다). 앱 화면 전용이라 높이 제한이 걸리는
    //    자리가 없다.
    // 3. "몇 정거장 남았나" 가 이 화면의 목적이다. 접으면 그 정보부터
    //    가려진다 — 마중 나갈 때를 잡으려는 사람에게 정작 필요한 걸 숨기는
    //    셈이라 대가가 이득보다 크다.

    var body: some View {
        // `stops` 가 비면 그릴 정류장이 없다. `RouteShape.position(travelled:)`
        // 은 이때 index 0 을 돌려주지만, 그 함수 자신의 문서가 밝히듯 이는
        // "안전한 값" 이 아니라 "그나마 덜 나쁜 값" 이다 — 인덱싱에서 죽지는
        // 않아도 정류장 0개짜리 노선도(출발점 하나만 뜬 화면)가 그려진다.
        // 서버가 빈 경로를 보낼 일은 거의 없지만(경로를 저장하려면 최소
        // 한 구간이 필요하다), `RouteShape(stops: [])` 가 올 수 있는 길이
        // 실제로 있으므로 이 뷰가 스스로 막는다.
        if shape.stops.isEmpty {
            EmptyView()
        } else {
            // 행은 0 부터 `stops.count` 까지(출발점 + 정류장 전부 + 집).
            // 이음은 행 사이에만 있으므로 행 0 뒤에는 없다.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0...shape.stops.count, id: \.self) { row in
                    if row > 0 {
                        connector(row - 1)     // 이음 번호 = 위 행의 번호
                    }
                    stopRow(row)
                }
            }
        }
    }

    /// 정류장 한 줄. 행 0 은 이름 없는 출발점이다.
    @ViewBuilder
    private func stopRow(_ row: Int) -> some View {
        // 점은 이음에 있으므로, 행은 지났는지 아닌지만 말한다 (자리 세기 참고).
        let passed = row <= passedThroughRow
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(passed ? state.tint : .white.opacity(0.25))
                .frame(width: 7, height: 7)
                .frame(width: railColumnWidth)

            Text(row == 0 ? "출발" : shape.stops[row - 1].name)
                .font(.system(size: 13, weight: row == position.index + 1 ? .semibold : .regular))
                // 긴 이름이 실제로 있다 — "출발역.은행앞".
                // 오늘 잠금화면에서 이미 잘려 본 자리다.
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
                .foregroundStyle(row == 0 ? .white.opacity(0.4)
                                          : .white.opacity(passed ? 0.6 : 0.4))
            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }

    /// 정류장 사이를 잇는 선. 지금 있는 구간이면 여기에 점을 찍는다.
    ///
    /// `index` 는 `stops[index]` 로 **향해 가는** 구간이다.
    @ViewBuilder
    private func connector(_ index: Int) -> some View {
        let here = index == position.index
        let passed = index < position.index
        // `here` 인 이음은 `legLabel` 과 `hereNote` 두 줄이 함께 들어갈 수 있어
        // 30, 아니면 한 줄(`legLabel`)뿐이라 16으로 좁힌다.
        //
        // 버스 도착이 붙는 이음은 줄이 하나 더 들어간다. 그 줄은 승차 15분 전부터만
        // 있으므로 평소 높이는 그대로다.
        let hasArrival = index == busArrivalIndex && busArrivalNote != nil
        // 칩 한 줄이 30, 그다음 차까지 두 줄이면 44.
        let arrivalHeight: CGFloat = hasArrival
            ? (state.busArrivalThenText != nil ? 44 : 30) : 0
        let height: CGFloat = (here ? 30 : 16) + arrivalHeight

        HStack(alignment: .center, spacing: 10) {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(passed ? state.tint.opacity(0.7) : .white.opacity(0.18))
                    .frame(width: 2, height: height)
                if here {
                    Circle()
                        .fill(.white)
                        .frame(width: 11, height: 11)
                        .shadow(color: state.tint.opacity(0.9), radius: 4)
                        // 구간을 얼마나 왔는지가 점의 높이다. 0 이면 맨 위,
                        // 1 이면 맨 아래. 점 지름만큼 빼서 선 밖으로 안 나가게 한다.
                        .offset(y: (height - 11) * position.fraction)
                }
            }
            .frame(width: railColumnWidth, height: height)

            VStack(alignment: .leading, spacing: 1) {
                if let label = legLabel(toward: index) {
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }
                if here, let note = hereNote {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                if hasArrival {
                    busArrivalChip
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 버스 도착을 붙일 이음. 지금 자리에서 앞으로 가장 가까운 버스 구간이다.
    ///
    /// **서버가 값을 실을 때만 그린다.** 서울 시내버스는 공공데이터에 도착정보가
    /// 없어서 영영 안 온다 — 그때 이 값은 nil 이고 줄이 안 붙는다.
    ///
    /// 노선번호로 다시 맞추지 않는다. 서버가 **다음** 버스 구간의 값만 싣기 때문이다.
    private var busArrivalIndex: Int? {
        guard state.busArrivalAt != nil else { return nil }
        return shape.stops.indices.first {
            $0 >= position.index && shape.stops[$0].mode == "bus"
        }
    }

    /// 그 이음에 적을 도착 한 줄. **문구는 `ContentState` 가 만든다** —
    /// 잠금화면이 같은 값을 쓰므로 두 화면이 갈라질 수 없다.
    private var busArrivalNote: String? { state.busArrivalLine }

    /// 다음에 탈 버스가 언제 오는가. **이 카드에서 가장 눈에 띄어야 하는 줄이다.**
    ///
    /// 처음에는 구간 이름과 같은 10pt 흐린 글씨로 그렸는데, 정류장에서 폰을 꺼내
    /// 이걸 보려는 사람에게는 안 보였다(2026-08-26 화면 확인). 뛸지 말지를 그
    /// 자리에서 정하는 값이라 노선도의 다른 글씨보다 커야 한다.
    ///
    /// **시각이 주인공이다.** 노선번호는 어느 버스인지 가리는 배지이고, 정류장 수는
    /// 곁들이다 — 그래서 크기와 굵기가 그 순서다.
    @ViewBuilder
    private var busArrivalChip: some View {
        // **번호만 오고 시각이 없을 때가 있다.** 승차 15분 창은 열렸는데 실시간
        // 도착정보에 그 차가 아직 안 잡힌 시간이다. 시각 칸을 비운 채로 표를
        // 그리면 "고장" 으로 읽히므로, 그때는 한 줄로 그렇다고 적는다.
        if state.busArrivalClockText == nil {
            HStack(spacing: 5) {
                Image(systemName: "bus.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(state.busArrivalNo.map { "\($0)번" } ?? "")
                    .font(.system(size: 11, weight: .heavy))
                Text("도착 정보 아직 없음")
                    .font(.system(size: 11, weight: .medium))
                    .opacity(0.7)
                refreshButton
            }
            .foregroundStyle(state.tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12).fill(state.tint.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(state.tint.opacity(0.22), lineWidth: 0.5))
        } else {
        // **칸을 맞춘다.** 두 줄이 나란히 있을 때 시각끼리·정류장 수끼리 세로로
        // 서지 않으면 "몇 분 더 기다리나" 를 견주기가 어렵다 — 그게 이 두 줄이
        // 있는 이유다. `Grid` 가 열 너비를 맞춰 준다.
        Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 3) {
            GridRow {
                // **아이콘을 별도 칸으로 뺀다.** 첫 칸에 아이콘과 노선번호를
                // 같이 넣으면 둘째 줄의 `그다음` 이 아이콘 자리부터 시작해
                // 노선번호와 어긋난다.
                Image(systemName: "bus.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(state.busArrivalNo.map { "\($0)번" } ?? "")
                    .font(.system(size: 11, weight: .heavy))
                Text(state.busArrivalClockText ?? "")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    // 두 줄의 시각이 폭이 달라도 자리가 맞으려면 오른쪽 정렬이어야 한다.
                    .gridColumnAlignment(.trailing)
                Text("도착")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.75)
                Text(state.busArrivalStopsText.map { "· \($0)" } ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .opacity(0.75)
                refreshButton
            }
            // **그다음 차.** 앞차를 놓쳤을 때 얼마를 더 기다리는지가 뛸지 말지를
            // 가른다 — 4분 뒤에 또 오면 안 뛰어도 되고, 20분이면 뛰어야 한다.
            //
            // **크기는 첫 줄과 같게 두고 위계는 흐림으로만 준다.** 글자를 줄이면
            // 칸 폭이 달라져 두 줄이 어긋난다(2026-08-26 화면 확인).
            if let clock = state.busArrivalThenClockText {
                GridRow {
                    // 아이콘 칸은 비운다 — 같은 노선이라 다시 그릴 것이 없다.
                    Text("")
                    // 노선이 다르면 번호를 적는다. 한 구간에 노선이 여럿일 수
                    // 있어서 둘째 줄이 다른 노선일 수 있다(2026-08-28).
                    Text(state.busArrivalThenNo.map { "\($0)번" } ?? "그다음")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.55)
                    Text(clock)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .opacity(0.7)
                    Text("도착")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(0.5)
                    Text(state.busArrivalThenStopsText.map { "· \($0)" } ?? "")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .opacity(0.5)
                }
            }
        }
        .foregroundStyle(state.tint)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(state.tint.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(state.tint.opacity(0.35), lineWidth: 0.5))
        }
    }

    /// 눌러서 지금 다시 묻는다. 넘겨받은 일이 없으면(가족 화면) 안 그린다.
    @ViewBuilder
    private var refreshButton: some View {
        if let onRefreshBusArrival {
            Button {
                guard !refreshing else { return }
                refreshing = true
                Task {
                    await onRefreshBusArrival()
                    refreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(refreshing ? 360 : 0))
                    .animation(refreshing
                               ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                               : .default, value: refreshing)
            }
            .buttonStyle(.plain)
            .padding(.leading, 1)
        }
    }

    /// 그 정류장으로 가는 수단과 시간. "버스 9분"
    ///
    /// 갈아타며 기다리는 시간은 **앞 정류장**에 붙어 있으므로 여기에 더한다 —
    /// 기다린 뒤에 타는 것이 이 구간이다.
    private func legLabel(toward index: Int) -> String? {
        guard shape.stops.indices.contains(index) else { return nil }
        let stop = shape.stops[index]
        let wait = index > 0 ? shape.stops[index - 1].waitSeconds : 0
        let minutes = max(1, (stop.seconds + wait) / 60)
        let label: String
        switch stop.mode {
        case "bus":    label = "버스"
        case "subway": label = "지하철"
        case "car":    label = "차"
        default:       label = "도보"    // 서버가 모르는 값을 보내도(문자열이라 디코딩은 늘 성공한다) 화면은 걸어가는 걸로 보여 준다.
        }
        return wait > 0 ? "\(label) \(minutes)분 (대기 포함)" : "\(label) \(minutes)분"
    }

    /// 지금 자리 옆에 붙는 한 줄. 끊겼으면 언제 것인지 적는다.
    ///
    /// **점을 예상 위치로 옮기지 않는다.** 보고가 없는 동안 지연되면 점이 집에
    /// 먼저 도착해 있는 거짓말을 한다. 아는 것만 말한다.
    ///
    /// **문턱이 3분인 것은 실측에서 나왔다.** 2026-08-14 실주행(68분, 갱신 165건)에서
    /// 2분으로 두면 다섯 번 떴는데 그중 셋이 12~18초 만에 사라졌다 — 읽기도 전에
    /// 없어지니 알려 주는 게 없고 화면만 어수선하다. 3분으로 올리면 그 셋이 문턱
    /// 아래로 내려가고, 긴 둘(7.6분·5.7분)만 남는다. 5분으로 더 올리면 잡는 사건은
    /// 똑같은 둘인데 그중 하나가 42초만 보여 다시 깜빡임이 된다.
    ///
    /// **이 문구가 실제로 뜨는 자리는 지하철이 아니다.** 설계할 때는 지하철에서
    /// 31분 먹통이 될 것으로 보고 만들었는데, 같은 실측에서 지하철(경의중앙선,
    /// 지상 구간)이 가장 촘촘했다 — 갱신 81건에 중앙 간격 8초, 최대 끊김 1.7분.
    /// 2분 넘게 끊긴 다섯 번은 전부 버스·도보 구간이었다.
    ///
    /// 원인은 신호가 아니라 **안 움직이는 것**이다. `distanceFilter` 가 150m 라
    /// 정류장에서 버스를 기다리면 폰이 아무것도 안 보낸다. 그래서 이 문구는 지금
    /// "어디 있는지 모른다" 가 아니라 사실상 "환승 대기 중" 에 뜬다 — 가족에게
    /// 필요 이상으로 불안하게 읽힌다. **heartbeat(안 움직여도 몇 분마다 보고)가
    /// 붙으면 이 문구는 진짜 신호 두절에서만 뜨게 되고, 그때 문턱도 다시 재야 한다.**
    ///
    /// **낡음의 기준은 배달 시각이 아니라 측정 시각이다.**
    ///
    /// 예전에는 `lastFixedAt` 만 봤다. 가족 쪽에서 그건 "갱신 푸시를 받은 시각" 인데,
    /// 2026-08-18 실주행에서 갱신이 APNs 안에서 최대 27분 붙잡혀 있다가 내려왔다.
    /// 폰은 방금 받았으니 이 문구가 뜨지 않았고, 화면은 27분 전 자리를 아무 표시 없이
    /// 지금 자리처럼 보여 줬다. **낡은 값을 낡았다고 말해 주는 장치가 없었다.**
    ///
    /// 그래서 서버가 상태에 실어 보내는 `measuredAt` 을 먼저 본다. 그 필드를 모르는
    /// 서버(구버전)가 보낸 상태에서는 예전처럼 받은 시각으로 판단한다.
    private var hereNote: String? {
        guard let at = state.measuredAt ?? lastFixedAt else { return nil }
        let minutes = Int(Date().timeIntervalSince(at) / 60)
        guard minutes >= staleNoteMinutes else { return nil }
        return "\(minutes)분 전 확인"
    }

    /// 몇 분부터 "N분 전 확인" 을 적을지. 근거는 `hereNote` 주석에 있다.
    private let staleNoteMinutes = 3
}

/// 남은 시간 카운트다운.
///
/// **시스템이 굴리는 형식만 쓴다.** Live Activity 뷰는 갱신이 올 때 한 번 그려서
/// 통째로 보관하고, 그 사이에는 `Text(timerInterval:)` 처럼 시스템이 아는 몇 가지만
/// 혼자 움직인다. 나머지는 얼어 있다 — `if` 갈림길도 그때 한 번만 지난다.
///
/// 이것 때문에 처음 고침이 실패했다. `isOverdue` 로 갈라 "늦음" 을 붙였는데,
/// 2026-08-19 실기기 시험에서 도착예정을 5분 44초 지나도 라벨이 안 붙었다. 갱신을
/// 끊은 동안에는 갈림길을 다시 안 지나기 때문이다. **그리고 그게 어제 결함이 난
/// 조건과 똑같다.**
///
/// 더 나쁜 것도 있었다. 서버는 `arrival = now + max(30, ...)` 로 **항상 미래**를
/// 보내므로, 푸시가 오는 순간에는 늘 늦지 않은 상태다. 라벨을 붙이는 방식으로는
/// 양쪽 다 놓친다.
///
/// 그래서 숫자 자체가 거짓말을 못 하게 만든다 — `Text(timerInterval:)` 은 0:00 에서
/// **멈춘다.** 늦었다는 사실은 부제의 `N분 지연` 이 말한다(서버가 `delaySeconds` 로
/// 보내고, 2026-08-19 실기기에서 `환승 대기 · 25분 지연` 으로 확인했다).
///
/// **초가 보이는 것은 이 정직함의 대가다.** 예전에 `mm:ss` 를 버리고
/// `style: .relative` 로 옮긴 이유가 "도착예정은 분 단위 값이라 초는 없는 정밀도를
/// 있는 척한다" 였는데, 자라는 숫자는 그보다 나쁘다 — 틀린 방향으로 확신을 준다.
struct CountdownText: View {
    let state: HomecomingAttributes.ContentState
    var font: Font = .system(size: 22, weight: .semibold, design: .rounded)

    var body: some View {
        if state.isStopped {
            Text("중지")
                .font(font)
                .foregroundStyle(state.tint)
        } else if state.stage.isFinished {
            Text("도착")
                .font(font)
                .foregroundStyle(state.tint)
        } else if !state.isOverdue {
            // 시스템이 굴린다. 도착예정을 지나면 0:00 에서 멈춘다.
            Text(timerInterval: state.countdownRange, countsDown: true)
                .font(font)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(state.tint)
        } else {
            // 그리는 순간에 이미 지나 있었다. 흔치 않지만(서버가 미래만 보내므로)
            // 이때는 얼마나 늦었는지 말할 수 있다.
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(state.expectedArrival, style: .relative)
                    .font(font)
                    .monospacedDigit()
                Text("늦음")
                    .font(.system(size: 12, weight: .semibold))
            }
            .multilineTextAlignment(.trailing)
            .foregroundStyle(state.tint)
        }
    }
}
