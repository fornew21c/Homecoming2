import CoreLocation
import SwiftUI

/// 이번 귀가에 쓸 경로를 고르고, 없으면 만든다.
///
/// 매일 같은 길을 타니까 만들 일은 거의 없고 고르는 일만 매번 있다. 그래서 고르기가
/// 화면의 주인이고 만들기는 버튼 하나다.
///
/// 경로를 고르면 도착예정이 그 경로의 실측 소요시간에서 나온다. 지하철처럼 위치가
/// 부정확한 구간에서도 흔들리지 않는다 — 애초에 위치로 나누는 게 아니다.
struct RouteCard: View {

    let store: RouteStore
    /// 고른 경로. nil 이면 거리 기반 추정으로 돈다.
    @Binding var selectedID: String?

    /// 경로 없이 도는 귀가에서 귀가자가 적는 예상 소요시간(분). nil 이면 안 적었다.
    ///
    /// **여기가 그 값을 적는 유일한 자리다.** `경로 없이` 를 고르면 도착예정을
    /// 계산할 근거가 사라지므로 사람에게 묻는다 — 저장된 경로에 실측 소요시간을
    /// 적어 두는 것과 같은 생각이다. 적지 않으면 귀가를 시작할 수 없다
    /// (`ContentView.canStart`).
    @Binding var plannedMinutes: Int?

    /// 경로의 끝. 만들기 화면이 마지막 구간의 도착지로 쓴다.
    let home: HomePlace
    /// 지금 있는 자리. 출발지를 미리 채우는 데 쓴다.
    let here: CLLocationCoordinate2D?

    @State private var isCreating = false
    /// 고치는 중인 경로. 목록에서 연필을 누르면 채워진다.
    @State private var editing: RouteDetail?
    @State private var loadingEdit: String?

    /// 귀가가 진행 중인지.
    ///
    /// 경로는 시작할 때 한 번 서버로 간다. 진행 중에 바꿔도 그 귀가에는 반영되지
    /// 않는다. 고를 수 있게 두면 바꾼 줄 알고 넘어가니, 잠그고 이유를 말한다.
    let isRunning: Bool

    private let accent = Color(red: 0.42, green: 0.85, blue: 0.62)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !store.isAvailable {
                Text("서버가 연결되어 있지 않습니다. 경로는 서버에만 존재하므로 쓸 수 없습니다.")
                    .font(.footnote)
                    .foregroundStyle(.orange.opacity(0.9))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if store.routes.isEmpty {
                        empty
                    } else {
                        ForEach(store.routes) { route in
                            row(route)
                        }
                    }
                    // **경로가 없어도 이 줄은 있어야 한다.** 회식·모임에서 귀가하는
                    // 사람은 저장된 경로가 아예 없고, 그때도 가족은 봐야 한다.
                    // 예전에는 경로 목록이 비면 안내문만 남아서, 경로를 만들지 않는
                    // 한 귀가를 시작할 길이 없었다.
                    noRouteRow
                    // **고른 줄 바로 아래에 둔다.** `noRouteRow` 안에 넣으면 버튼
                    // 안의 버튼이 되어 어느 것을 눌렀는지 iOS 가 가리지 못한다.
                    if selectedID == nil { plannedMinutesRow }
                }
                .disabled(isRunning)
                .opacity(isRunning ? 0.45 : 1)

                if isRunning {
                    Text("귀가 중에는 바꿀 수 없습니다. 경로는 시작할 때 서버로 갑니다.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            if let message = store.lastError {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.06))
        )
        .task { await store.refresh() }
        .sheet(item: $editing) { detail in
            RouteEditor(
                store: store,
                home: home,
                origin: here,
                editing: detail,
                onSaved: { saved in if !isRunning { selectedID = saved } },
                onDeleted: { if selectedID == detail.id { selectedID = nil } }
            )
        }
        .sheet(isPresented: $isCreating) {
            RouteEditor(store: store, home: home, origin: here, editing: nil) { saved in
                // 방금 만든 경로를 바로 고른다. 만들고 또 고르게 하면 한 단계가 남는다.
                if !isRunning { selectedID = saved }
            }
        }
    }

    /// 고칠 경로를 통째로 받아 온다. 목록은 요약만 갖고 있다.
    private func beginEditing(_ route: HomecomingRoute) async {
        loadingEdit = route.id
        defer { loadingEdit = nil }
        editing = await store.detail(of: route.id)
    }

    // MARK: - 조각

    private var header: some View {
        HStack(spacing: 10) {
            Text("귀가 경로")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if store.isWorking {
                ProgressView().controlSize(.small).tint(.white.opacity(0.5))
            }
            if store.isAvailable {
                Button { isCreating = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                // 귀가 중에 경로를 새로 만드는 것 자체는 막을 이유가 없다.
                // 그 귀가에 반영되지 않을 뿐이고, 그건 고르기 쪽에서 말한다.
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("저장된 경로가 없습니다.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
            Text("＋ 를 눌러 만드세요. 대중교통 앱이 알려 주는 구간과 소요시간을 옮겨 적으면 됩니다.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.38))
        }
    }

    private func row(_ route: HomecomingRoute) -> some View {
        let picked = selectedID == route.id
        return Button {
            // 같은 것을 다시 누르면 해제한다. 경로 없이 도는 것도 정상 상태다.
            selectedID = picked ? nil : route.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(picked ? accent : .white.opacity(0.25))

                VStack(alignment: .leading, spacing: 2) {
                    Text(route.name)
                        .font(.system(size: 14, weight: picked ? .semibold : .regular))
                        .foregroundStyle(.white)
                    Text("\(route.durationText) · \(route.homeName ?? "집")")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)

                // 고치기는 고르기와 **다른 버튼**이다. 줄 전체를 누르면 고쳐지면
                // 이번 귀가에 쓸 경로를 고르려던 사람이 편집기로 끌려간다.
                if loadingEdit == route.id {
                    ProgressView().controlSize(.small).tint(.white.opacity(0.5))
                } else {
                    Button {
                        Task { await beginEditing(route) }
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(picked ? accent.opacity(0.12) : .white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    /// 경로를 쓰지 않는 선택. 다른 길로 가는 날이 있으니 명시적으로 둔다.
    private var noRouteRow: some View {
        let picked = selectedID == nil
        return Button {
            selectedID = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(picked ? accent : .white.opacity(0.25))

                VStack(alignment: .leading, spacing: 2) {
                    Text("경로 없이")
                        .font(.system(size: 14, weight: picked ? .semibold : .regular))
                        .foregroundStyle(.white)
                    Text("남은 거리로 도착 예정을 짐작합니다")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(picked ? accent.opacity(0.12) : .white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    /// 얼마나 걸리는지 적는 자리. `경로 없이` 를 골랐을 때만 나온다.
    ///
    /// **계산하지 않고 묻는다.** 어느 길로 갈지 모르는 귀가에서 도착예정을 짐작하면
    /// 가족 화면의 카운트다운이 근거 없이 흔들린다. 사람은 대개 안다 — "한 시간쯤".
    ///
    /// 흔한 값을 버튼으로 두고 5분 단위로 다듬게 한다. 숫자 키패드를 띄우지 않는
    /// 이유는 이 화면이 출발 직전에 열리는 자리라서다. 한 손으로 두 번 눌러 끝나야 한다.
    private var plannedMinutesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("얼마나 걸려요?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 0)
                if let minutes = plannedMinutes {
                    // 도착 시각을 같이 보여 준다. 분만 적으면 몇 시에 닿는지
                    // 머리로 더해야 하고, 가족이 보는 것은 그 시각이다.
                    Text("\(Self.clockText(minutesFromNow: minutes)) 도착")
                        .font(.system(size: 12))
                        .foregroundStyle(accent.opacity(0.9))
                }
            }

            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.self) { minutes in
                    Button {
                        plannedMinutes = minutes
                    } label: {
                        Text("\(minutes)분")
                            .font(.system(size: 13,
                                          weight: plannedMinutes == minutes ? .semibold : .regular))
                            .foregroundStyle(plannedMinutes == minutes ? accent : .white.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(plannedMinutes == minutes
                                          ? accent.opacity(0.16) : .white.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let minutes = plannedMinutes {
                HStack(spacing: 10) {
                    stepButton("minus", to: minutes - Self.step)
                    Text("\(minutes)분")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .frame(minWidth: 54)
                    stepButton("plus", to: minutes + Self.step)
                    Spacer(minLength: 0)
                    Button("지우기") { plannedMinutes = nil }
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                        .buttonStyle(.plain)
                }
            } else {
                Text("적지 않으면 시작할 수 없습니다. 가족 화면의 도착 시각이 이 값에서 나옵니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.04))
        )
    }

    private func stepButton(_ symbol: String, to minutes: Int) -> some View {
        Button {
            plannedMinutes = min(Self.maximum, max(Self.step, minutes))
        } label: {
            Image(systemName: "\(symbol).circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.55))
        }
        .buttonStyle(.plain)
    }

    /// 흔한 값. 30분(가까운 회식)에서 90분(먼 곳)까지가 이 앱이 실제로 다뤄 온 폭이다
    /// — 저장된 퇴근 경로가 79~82분이다.
    private static let presets = [20, 30, 45, 60, 90]
    private static let step = 5
    private static let maximum = 480

    /// 지금부터 N분 뒤의 시각. "18:42" 처럼 적는다.
    private static func clockText(minutesFromNow minutes: Int) -> String {
        let at = Date().addingTimeInterval(TimeInterval(minutes * 60))
        return at.formatted(.dateTime.hour().minute())
    }
}
