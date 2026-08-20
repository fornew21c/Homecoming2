# Homecoming2

귀가하는 사람의 위치를 가족이 실시간으로 보는 iOS 앱 + 서버.
`Homecoming` 을 복사해 만든 **별개 앱**이다(번들 `com.kona.homecoming2`).

## 먼저 읽을 것

- **[`docs/HANDOFF-2026-08-20.md`](docs/HANDOFF-2026-08-20.md)** — 배포 정보, 이 환경의
  함정(사내망 TLS 등), 지금까지 한 일, 정리 안 한 것
- **[`docs/superpowers/specs/2026-08-20-progress-unification-design.md`](docs/superpowers/specs/2026-08-20-progress-unification-design.md)**
  — 카드와 지도의 진행도를 한 벌로 합쳤다(구현·검증 완료). 진행도를 건드리기 전에 읽는다

## 이 저장소를 다룰 때

**용어는 `귀가` 다.** 퇴근이 아니다 — 직장에서만 집에 가는 것이 아니라
회식·모임에서도 귀가한다. 화면 문구는 이미 전부 `귀가` 이고 주석에만 "퇴근" 이 남아 있다.

**값을 짐작해서 넣지 않는다.** 좌표·코드·소요시간은 저장소나 공공데이터에서 확인한다.
비교 주장(`A 가 B 보다 크다`)을 하기 전에 재본다. 확인할 수 없으면 그렇다고 말한다.
이 코드의 주석들이 그 규율로 쓰여 있다 — "실제로 이렇게 틀렸다" 는 기록이 붙어 있고,
틀린 값을 화면에 그리는 것을 아무것도 안 그리는 것보다 나쁘게 본다.

**`Homecoming.xcodeproj` 는 생성물이다.** 파일을 더하면
`ruby Tools/generate_project.rb` 로 재생성한다. 번들 ID·표시명의 원본은 그 스크립트다.

**경로의 좌표열은 저장할 때 박힌다.** 그리기 로직을 고쳐도 이미 저장된 경로에는
반영되지 않는다 — 앱에서 경로를 다시 저장해야 한다.

**와이어 프로토콜은 추가만 한다.** `ContentState` 에 필드를 더하면
`CodingKeys` · `init(from:)` · `encode(to:)` 세 곳을 같이 고쳐야 한다
(`Shared/HomecomingAttributes.swift` 의 경고 주석 참고 — 빠뜨리면 값이 조용히 사라진다).

## 검증

시뮬레이터는 사내망 TLS 때문에 배포 서버(HTTPS)에 못 붙는다. 로컬 서버를 띄우고
`-homecomingBackend http://localhost:8811` 로 실행한다. 실기기는 정상이다.

진행도(노선도의 점 · 지도의 색 분리)를 고쳤으면 **다시 잰다.** 두 화면이 같은
자리를 가리키는지 앱 원본을 컴파일해 견준다. 지금 남은 차이는 28.4km 에서 7m 이고
그건 자 차이다(앱 측지선 · 서버 구). **자른 길이를 앱 자로 되재면 안 된다** — 요청한
값과 같은 것이 당연해서 0m 가 나온다. 자른 자리를 서버 자로 되재야 값이 나온다.

```bash
python3 Tools/verify-progress-sync.py          # 카드 vs 지도, 실제 경로 28.4km
cd Server && python3 -m unittest discover      # 서버 시험 38개
```

```bash
source Server/.env.local                       # 공공데이터 키
python3 Server/homecoming_server.py --port 8811
railway up --detach --service homecoming2      # 배포
```
