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
            } else if store.routes.isEmpty {
                empty
            } else {
                VStack(spacing: 8) {
                    ForEach(store.routes) { route in
                        row(route)
                    }
                    noRouteRow
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
}
