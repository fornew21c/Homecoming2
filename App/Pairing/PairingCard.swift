import SwiftUI

/// 누가 내 귀가를 볼 수 있는지 관리하는 화면 조각.
///
/// 한 사람이 귀가자이면서 동시에 다른 사람을 지켜볼 수 있으므로 두 역할을 한 카드에 담는다.
struct PairingCard: View {

    let store: PairingStore
    let travelerName: String

    @State private var enteredCode = ""
    @State private var showingInvite = false
    @FocusState private var codeFocused: Bool

    private let accent = Color(red: 0.42, green: 0.85, blue: 0.62)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("가족 연결")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            if !store.isAvailable {
                Text("서버가 연결되어 있지 않습니다. 연결은 서버에만 존재하므로 페어링을 쓸 수 없습니다.")
                    .font(.footnote)
                    .foregroundStyle(.orange.opacity(0.9))
            } else {
                travelerSection
                Divider().overlay(.white.opacity(0.1))
                watcherSection
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
    }

    // MARK: - 귀가자: 내 귀가를 보는 사람들

    private var travelerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("내 귀가를 보는 가족")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))

            if store.watchers.isEmpty {
                Text("아직 없습니다. 초대 코드를 만들어 가족에게 전달하세요.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                ForEach(store.watchers) { member in
                    memberRow(member, symbol: "eye.fill")
                }
            }

            if let invite = store.invite, invite.isValid {
                HStack(spacing: 10) {
                    Text(invite.code)
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .kerning(4)
                        .foregroundStyle(accent)
                    Spacer()
                    ShareLink(item: "귀가 마중 초대 코드: \(invite.code)") {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accent.opacity(0.12))
                )
                Text("30분 안에 가족이 입력해야 합니다.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }

            Button {
                Task { await store.createInvite(travelerName: travelerName) }
            } label: {
                Text(store.invite == nil ? "초대 코드 만들기" : "새 코드 만들기")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.1))
                    )
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .disabled(store.isWorking)
        }
    }

    // MARK: - 가족: 내가 보고 있는 사람들

    private var watcherSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("내가 지켜보는 사람")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))

            ForEach(store.watching) { member in
                memberRow(member, symbol: "figure.walk")
            }

            HStack(spacing: 8) {
                TextField("초대 코드", text: $enteredCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .focused($codeFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.08))
                    )
                    .foregroundStyle(.white)

                Button {
                    codeFocused = false
                    Task {
                        if await store.accept(code: enteredCode) { enteredCode = "" }
                    }
                } label: {
                    Text("연결")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(accent.opacity(0.22))
                        )
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .disabled(enteredCode.isEmpty || store.isWorking)
            }

            HStack {
                Text("가족에게 보일 내 이름")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                TextField("가족", text: Binding(
                    get: { store.myName },
                    set: { store.myName = $0 }
                ))
                .multilineTextAlignment(.trailing)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
            }
        }
    }

    // MARK: - 공통

    private func memberRow(_ member: PairMember, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            Text(member.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            Button {
                Task { await store.unlink(member) }
            } label: {
                Text("해제")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .disabled(store.isWorking)
        }
    }
}
