import CoreLocation
import SwiftUI

/// 귀가 경로를 폰에서 만든다.
///
/// **넣는 것은 두 가지뿐이다** — 어디서 어디까지, 그리고 몇 분.
/// 좌표열은 `RouteTracer` 가 채우고, 도착예정은 여기 적은 분에서 나온다.
///
/// 분을 사용자가 넣는 이유 — 대중교통 앱이 이미 알고 있다. "1시간 24분" 이라고
/// 화면에 떠 있다. 그걸 옮겨 적는 게 위치로 예측하는 것보다 훨씬 정확하다.
/// 실제로 같은 경로에서 위치로 예측했을 때 도착예정이 18.8시간까지 튀었다.
struct RouteEditor: View {

    let store: RouteStore
    /// 경로의 끝. 집은 이미 정해져 있으니 다시 묻지 않는다.
    let home: HomePlace
    /// 출발지. 회사에서 출발하니 대개 지금 있는 자리다.
    let origin: CLLocationCoordinate2D?

    /// 고칠 경로. nil 이면 새로 만든다.
    ///
    /// **고치는 것과 만드는 것은 같은 화면이다.** 넣는 값이 똑같기 때문이다.
    /// 다른 건 시작할 때 값이 채워져 있는지와, 저장할 때 id 를 함께 보내는지뿐이다.
    var editing: RouteDetail?

    /// 저장에 성공하면 그 경로 id 를 준다. 부른 쪽이 바로 고를 수 있게.
    var onSaved: (String) -> Void
    /// 지웠을 때. 고르기 화면이 선택을 놓아야 한다.
    var onDeleted: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var steps: [RouteTracer.Step] = [
        .init(mode: .walk, minutes: 5),
        .init(mode: .bus, minutes: 15),
    ]
    @State private var originCoordinate: CLLocationCoordinate2D?
    @State private var originName = ""
    @State private var isSaving = false
    @State private var failure: String?

    /// 저장은 됐지만 알려야 할 것. 이게 있으면 창을 자동으로 닫지 않는다 —
    /// 닫히면 읽을 새가 없다.
    @State private var notice: String?
    @State private var confirmingDelete = false

    private let accent = Color(red: 0.42, green: 0.85, blue: 0.62)

    /// 전체 소요시간. 구간 시간의 합이다.
    private var totalMinutes: Int { steps.reduce(0) { $0 + max(1, $1.minutes) } }

    /// 마지막 구간의 도착지는 집이다. 좌표를 따로 묻지 않는다.
    /// 이 구간의 지도를 열 자리 — **직전에 찍어 둔 지점**.
    ///
    /// 앞쪽 구간 중 좌표가 있는 마지막 것을 쓴다. 대기 구간은 좌표가 없어서
    /// 건너뛴다. 아직 아무것도 안 찍었으면 출발지, 그것도 없으면 집이다.
    private func startPoint(before index: Int) -> CLLocationCoordinate2D {
        for step in steps[..<index].reversed() {
            if let to = step.to { return to }
        }
        return originCoordinate ?? origin ?? home.coordinate
    }

    private var resolvedSteps: [RouteTracer.Step] {
        guard var last = steps.last else { return steps }
        last.to = home.coordinate
        last.toName = last.toName.isEmpty ? home.name : last.toName
        return steps.dropLast() + [last]
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && originCoordinate != nil
            && steps.count >= 1
            // 마지막을 뺀 이동 구간은 좌표가 있어야 한다. 마지막은 집이 채운다.
            && steps.dropLast().allSatisfy { !$0.mode.moves || $0.to != nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameField
                    originField
                    stepList
                    summary
                    if editing != nil { deleteButton }
                    if let failure {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    // **저장은 됐는데 선이 실제 노선이 아닌 경우.** 그대로 닫으면
                    // 아무도 모른다 — 지도에는 그럴듯한 선이 그려져 있고, 그것이
                    // 자동차 길이라는 것은 저장한 사람만 알 수 있다.
                    if let notice {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(notice)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                            Button("확인") { dismiss() }
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(editing == nil ? "경로 만들기" : "경로 고치기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("저장") { Task { await save() } }
                            .disabled(!canSave)
                    }
                }
            }
            .task {
                if let editing {
                    // 고치는 것이면 저장된 값으로 채운다.
                    name = editing.name
                    steps = editing.steps
                    originCoordinate = editing.origin
                    originName = editing.origin == nil ? "" : "저장된 출발지"
                    return
                }
                // 출발지는 대개 지금 있는 자리다. 미리 채워 두고 바꿀 수 있게 한다.
                if originCoordinate == nil, let origin {
                    originCoordinate = origin
                    originName = "현재 위치"
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 조각

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("이름")
            TextField("회사-집", text: $name)
                .textFieldStyle(.plain)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
                .foregroundStyle(.white)
            // 같은 이름으로 다시 저장하면 고치는 것이다. 사용자가 알아야 한다.
            Text("같은 이름으로 저장하면 그 경로를 고칩니다.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var originField: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("출발")
            PlacePicker(
                title: originName.isEmpty ? "출발지를 찾으세요" : originName,
                near: origin ?? home.coordinate,
                store: store
            ) { hit in
                originCoordinate = hit.coordinate
                originName = hit.name
            }
        }
    }

    /// 이 구간의 도착지에서 **탈 버스의 노선번호.** 없으면 nil.
    ///
    /// 이 구간이 버스면 그 번호다. 아니면 다음 구간의 번호다 — 승차 정류장은
    /// 도보 구간의 도착지이고 그 구간에는 노선번호가 없기 때문이다.
    /// `퇴근길` 의 `풍산역 버스정류장`(도보) → `999`(버스)가 그 자리다.
    private func boardingRouteNo(at index: Int) -> String? {
        func number(_ step: RouteTracer.Step) -> String? {
            guard step.mode == .bus else { return nil }
            let no = (step.busNo ?? "").trimmingCharacters(in: .whitespaces)
            return no.isEmpty ? nil : no
        }
        if let own = number(steps[index]) { return own }
        let next = index + 1
        return next < steps.count ? number(steps[next]) : nil
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                label("구간")
                Spacer()
                Button {
                    steps.append(.init(mode: .bus, minutes: 10))
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(accent)
                }
            }

            ForEach(steps.indices, id: \.self) { index in
                StepRow(
                    step: $steps[index],
                    // **이전 지점에서 지도를 연다.** 전에는 모든 구간이 출발지
                    // 하나를 썼다 — 다섯 번째 구간을 찍으려고 지도를 열면 회사가
                    // 나와서, 일산까지 손으로 끌어야 했다. 다음 정류장은 이전
                    // 정류장 근처에 있으니 거기서 시작하는 것이 맞다.
                    near: startPoint(before: index),
                    isLast: index == steps.count - 1,
                    homeName: home.name,
                    store: store,
                    boardingRouteNo: boardingRouteNo(at: index),
                    onDelete: steps.count > 1 ? { steps.remove(at: index) } : nil
                )
            }
        }
    }

    private var summary: some View {
        HStack {
            Text("총 \(totalMinutes)분")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Text("도착예정은 이 시간에서 나옵니다")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.10)))
    }

    /// 지우기. 되돌릴 수 없으니 한 번 묻는다.
    private var deleteButton: some View {
        Button(role: .destructive) { confirmingDelete = true } label: {
            Text("이 경로 지우기")
                .font(.system(size: 14))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.red.opacity(0.15)))
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .confirmationDialog("이 경로를 지울까요?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("지우기", role: .destructive) { Task { await remove() } }
            Button("그만두기", role: .cancel) {}
        } message: {
            Text("되돌릴 수 없습니다. 진행 중인 귀가가 이 경로를 쓰고 있으면 남은 시간을 거리로 짐작하게 됩니다.")
        }
    }

    private func remove() async {
        guard let editing else { return }
        isSaving = true
        defer { isSaving = false }
        if await store.delete(editing.id) {
            onDeleted?()
            dismiss()
        } else {
            failure = store.lastError ?? "지우지 못했습니다."
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.75))
    }

    // MARK: - 저장

    private func save() async {
        guard let originCoordinate else { return }
        isSaving = true
        defer { isSaving = false }
        failure = nil
        notice = nil

        do {
            var tracer = RouteTracer()
            // 버스 구간에 노선번호가 있으면 그 노선이 지나는 정류장을 물어 온다.
            // 서버만 공공데이터 키를 갖고 있으므로 이쪽으로 나간다.
            tracer.subwayWaypoints = { [store] fromName, toName in
                await store.subwayWaypoints(fromName: fromName, toName: toName)
            }
            tracer.busWaypoints = { [store] no, from, to, fromName, toName in
                await store.busWaypoints(no: no, from: from, to: to,
                                         fromName: fromName, toName: toName)
            }
            let plotted = try await tracer.plot(origin: originCoordinate, steps: resolvedSteps)
            let draft = RouteDraft(name: name.trimmingCharacters(in: .whitespaces),
                                   home: home, legs: plotted.legs)
            guard let id = await store.save(draft, replacing: editing?.id) else {
                failure = store.lastError ?? "저장하지 못했습니다."
                return
            }
            onSaved(id)

            // **노선 자료를 못 찾은 버스 구간이 있으면 말하고 닫지 않는다.**
            //
            // 저장은 성공했고 경로는 쓸 수 있다. 다만 그 구간의 선은 실제 노선이
            // 아니라 자동차 길이다 — 가족 지도에 그려질 모양이 실제로 버스가 가는
            // 길과 다르다. 조용히 닫으면 그 사실이 아무 데도 남지 않는다.
            //
            // 지하철도 같다. 두 역이 함께 있는 노선을 못 찾으면 두 역 직선으로
            // 그리는데, 실제 선로가 거기서 1km 넘게 벗어날 수 있다(2026-08-25
            // 실주행에서 그것 때문에 이탈로 오판됐다).
            var reasons: [String] = []
            if !plotted.busFallbacks.isEmpty {
                reasons.append("\(plotted.busFallbacks.joined(separator: ", "))번 버스 노선 자료를"
                               + " 못 찾아 자동차 경로로 그렸습니다")
            }
            if !plotted.subwayFallbacks.isEmpty {
                reasons.append("\(plotted.subwayFallbacks.joined(separator: ", ")) 구간의 지하철"
                               + " 노선을 못 찾아 두 역을 직선으로 그렸습니다")
            }
            if reasons.isEmpty {
                dismiss()
            } else {
                notice = "저장했습니다. 다만 " + reasons.joined(separator: ", 그리고 ")
                    + " — 지도의 선 모양이 실제 노선과 다를 수 있어요."
            }
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - 구간 한 줄

private struct StepRow: View {

    @Binding var step: RouteTracer.Step
    let near: CLLocationCoordinate2D
    /// 마지막 구간의 도착지는 집이다. 좌표를 묻지 않는다.
    let isLast: Bool
    let homeName: String
    let store: RouteStore
    /// **이 구간의 도착지에서 탈 버스의 노선번호.**
    ///
    /// 이 구간이 버스면 그 번호이고, 아니면 **다음 구간**의 번호다 — 승차
    /// 정류장은 도보 구간의 도착지라 그 구간에는 노선번호가 없다. `퇴근길` 의
    /// `풍산역 버스정류장` 이 그 자리다.
    let boardingRouteNo: String?
    let onDelete: (() -> Void)?

    /// 검색이 준 원래 이름. 사용자가 이름을 고쳐도 "어디를 찍었는지" 는 남아야 한다.
    @State private var found = ""

    /// 아직 칩이 안 된, 치고 있는 번호.
    @State private var routeDraft = ""

    /// **같은 번호는 한 번만 쌓는다.** 두 번 물으면 한도만 태운다.
    private func commitRoute() {
        let no = routeDraft.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
            .trimmingCharacters(in: .whitespaces)
        routeDraft = ""
        guard !no.isEmpty, !step.busNos.contains(no) else { return }
        step.busNos.append(no)
        // 첫 노선은 `busNo` 에도 남긴다 — 선을 그리는 것과 옛 서버가 그 값을 쓴다.
        step.busNo = step.busNos.first
    }

    /// 등록된 노선들. `ⓧ` 로 하나씩 지운다.
    @ViewBuilder
    private var routeChips: some View {
        if step.mode == .bus, !step.busNos.isEmpty {
            HStack(spacing: 6) {
                ForEach(step.busNos, id: \.self) { no in
                    HStack(spacing: 4) {
                        Text(no)
                            .font(.system(size: 12, weight: .semibold))
                        Button {
                            step.busNos.removeAll { $0 == no }
                            step.busNo = step.busNos.first
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.12)))
                }
                Spacer(minLength: 0)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $step.mode) {
                    ForEach(RouteLeg.Mode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white.opacity(0.8))

                Spacer(minLength: 0)

                // **버스에만 노선번호를 묻는다.** 있으면 그 노선이 실제로 지나는
                // 정류장을 따라 선을 그린다(첫 노선으로 그린다). 비워 두면
                // 지금까지처럼 자동차 경로다.
                //
                // **여럿을 받는다.** 같은 구간을 두 노선이 가는 경우가 있다 —
                // 국회의사당역 → 신촌로터리를 163 과 6713 이 같이 간다
                // (2026-08-28 실측). 하나만 적으면 나머지가 도착 칩에 안 나온다.
                if step.mode == .bus {
                    TextField("노선", text: $routeDraft)
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .frame(width: 52)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                        .foregroundStyle(.white)
                        .submitLabel(.done)
                        .onSubmit { commitRoute() }
                        // 쉼표나 공백을 쳐도 그때 쌓인다. 쉼표로 적던 습관이
                        // 있어도 그대로 통한다 — 노선번호에는 둘 다 안 들어간다
                        // (서울 723개 확인, 괄호와 하이픈만 있다).
                        .onChange(of: routeDraft) { _, new in
                            if new.hasSuffix(",") || new.hasSuffix(" ") { commitRoute() }
                        }
                }

                Stepper("\(max(1, step.minutes))분", value: $step.minutes, in: 1...240)
                    .fixedSize()
                    .foregroundStyle(.white)

                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }

            routeChips

            if isLast {
                // 마지막은 집이다. 고를 것이 없다.
                Text("도착 · \(homeName)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
            } else if step.mode.moves {
                PlacePicker(
                    title: step.to == nil ? "도착지를 찾으세요" : (found.isEmpty ? "위치 지정됨" : found),
                    near: near,
                    store: store,
                    routeNo: boardingRouteNo
                ) { hit in
                    found = hit.name
                    step.to = hit.coordinate
                    // 검색이 준 이름을 그대로 쓰되, 고칠 수 있게 둔다.
                    if step.toName.isEmpty { step.toName = hit.name }
                }

                // **이름은 따로 고칠 수 있어야 한다.**
                //
                // 버스정류장은 애플 지도에 시설로 등록되어 있지 않다. "환승로터리" 를
                // 찾으면 근처 GS25 가 나온다. 좌표는 245m 차이라 묻히지만(이탈 판정
                // 기준이 1km) 이름은 사람이 읽는 값이다 — 가족 카드에 "GS25까지 9분"
                // 이 뜨면 그건 고장으로 보인다.
                if step.to != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "textformat")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                        TextField("카드에 보일 이름", text: $step.toName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
                }
            } else {
                // 대기 구간은 자리가 바뀌지 않는다. 이름만 있으면 카드에 뜬다.
                TextField("163번 대기", text: $step.toName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
                    .foregroundStyle(.white)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
    }
}

// MARK: - 장소 고르기

/// 이름으로 장소를 찾아 하나 고른다.
private struct PlacePicker: View {

    let title: String
    let near: CLLocationCoordinate2D
    let store: RouteStore
    /// 이 자리에서 탈 버스의 노선번호. 있으면 그 노선이 서는 기둥만 나온다.
    ///
    /// **이 구간의 것이 아닐 수 있다.** 승차 정류장은 도보 구간의 도착지라
    /// 그 구간에는 노선번호가 없다 — 부르는 쪽이 `다음 구간의 것` 을 넘긴다.
    var routeNo: String? = nil
    var onPick: (PlaceSearch.Hit) -> Void

    private let accent = Color(red: 0.42, green: 0.85, blue: 0.62)

    /// 같은 이름이 방향별로 여럿이라 ARS 번호로 구분한다.
    /// 정류장 기둥에 적힌 번호라 사람이 눈으로 맞출 수 있다.
    /// 목록 한 줄의 부제. **같은 이름이 여럿일 때 이것으로 고른다.**
    ///
    /// 기둥번호만으로는 앉아서 고를 수가 없다 — 그 번호는 정류장에 가서 읽는
    /// 값이다. 노선번호를 함께 물었으면 `다음 정류장` 이 오고, 그게 가는
    /// 방향을 말해 준다(풍산역 20753 은 애니골입구, 58271 은 밤가시7.8단지).
    private func stopContext(_ stop: BusStop) -> String? {
        var parts: [String] = []
        if let number = stop.number { parts.append("정류장 번호 \(number)") }
        if let next = stop.nextStop {
            // 서버가 마지막 정류장에는 `종점` 을 보낸다. `다음 종점` 은 말이 안 된다.
            parts.append(next == "종점" ? "종점" : "다음 \(next)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func findStops(_ query: String) {
        stopLookup?.cancel()
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else {
            stops = []
            isLookingUp = false
            return
        }
        isLookingUp = true
        stopLookup = Task {
            // 한 글자마다 서버를 부를 이유가 없다.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let found = await store.stopsNamed(query, route: routeNo)
            guard !Task.isCancelled else { return }
            stops = found
            isLookingUp = false
        }
    }

    @State private var text = ""
    @State private var isOpen = false
    @State private var isMapping = false
    /// 공공데이터가 아는 정류장. 애플 지도보다 **먼저** 보여 준다.
    @State private var stops: [BusStop] = []
    @State private var stopLookup: Task<Void, Never>?
    /// 조회가 도는 중. 예전에는 애플 지도가 이 표시를 들고 있었다.
    @State private var isLookingUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { isOpen.toggle() } label: {
                HStack {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(title.hasPrefix("도착지") || title.hasPrefix("출발지") ? 0.35 : 0.9))
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
            }
            .buttonStyle(.plain)

            if isOpen {
                TextField("역·정류장 이름", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
                    .foregroundStyle(.white)
                    .onChange(of: text) { _, new in
                        findStops(new)
                    }

                if isLookingUp {
                    ProgressView().controlSize(.small).tint(.white.opacity(0.4))
                }

                // **공공데이터 정류장만 보여 준다.**
                //
                // 예전에는 애플 지도(`MKLocalSearch`)도 같이 두드려 그 결과를
                // 아래에 붙였다. 애플 지도에는 버스정류장이 **시설로 없어서**
                // 이름을 치면 근처 가게가 온다 — `신촌로터리` 를 치면 종로김밥·
                // 탐엔탐스·한솥도시락이 나왔다. 2026-08-20 에는 그렇게 고른
                // GS25 가 가족 잠금화면에 `GS25까지 9분` 으로 떴다.
                //
                // 정류장을 위에 두는 것으로 눌러 왔는데, **경기 정류장이 이름으로
                // 안 나오던 동안에는 그 방어가 통하지 않았다** — 위가 늘 비어서
                // 애플 지도밖에 고를 게 없었다. 서버가 경기까지 찾게 된 지금
                // (2026-08-27) 정류장 목록만으로 충분하다.
                //
                // 정류장이 아닌 자리(회사·건물)는 아래 `지도에서 찍기` 로 간다.
                ForEach(stops) { stop in
                    Button {
                        onPick(PlaceSearch.Hit(name: stop.name, context: stopContext(stop),
                                               coordinate: stop.coordinate))
                        text = ""
                        isOpen = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "bus.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(stop.name)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white)
                                if let context = stopContext(stop) {
                                    Text(context)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                    }
                    .buttonStyle(.plain)
                }

                if stops.isEmpty, !isLookingUp,
                   text.trimmingCharacters(in: .whitespaces).count >= 2 {
                    Text("그 이름의 정류장이 없습니다. 아래에서 직접 찍으세요.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 10)
                }

                // **검색으로는 못 찾는 자리가 늘 있다.** 회사·건물처럼 정류장이
                // 아닌 목적지가 그렇다. 그 자리가 어딘지는 쓰는 사람이 아니까,
                // 직접 찍을 길을 항상 열어 둔다.
                Button { isMapping = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 11))
                        Text("지도에서 찍기")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $isMapping) {
            MapPointPicker(
                start: near,
                title: text,
                findStops: { await store.nearbyStops($0) },
                searchStops: { await store.stopsNamed($0) }
            ) { officialName, coordinate in
                // 정류장을 골랐으면 그 공식 이름을, 지도만 찍었으면 사용자가 친
                // 글자를 쓴다. 지도에서 찍는 건 검색이 그 이름을 모를 때다.
                let name = officialName ?? text
                onPick(PlaceSearch.Hit(name: name, context: nil, coordinate: coordinate))
                text = ""
                isOpen = false
            }
        }
    }
}
