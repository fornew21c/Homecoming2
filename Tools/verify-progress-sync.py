#!/usr/bin/env python3
"""카드의 노선도 점과 지도의 색 분리가 **같은 자리**를 말하는지 잰다.

    python3 Tools/verify-progress-sync.py

두 화면이 "얼마나 왔나" 를 각자 계산하던 것을 서버 진행도(`travelledMeters`)
한 벌로 합쳤다. 이 스크립트가 그것을 되잰다 — 2026-08-20 설계문서
(`docs/superpowers/specs/2026-08-20-progress-unification-design.md`)의 표를
같은 방식으로 다시 찍는다.

**무엇을 재는가.** 카드는 서버가 준 값을 그대로 쓰므로(양 끝만 자른다) 카드 쪽
숫자는 곧 서버의 진행도다. 재는 것은 **지도가 같은 축에서 같은 자리를 자르는지**다.
지도는 좌표열을 따라 누적으로 자르므로 축이 어긋날 수 있다 — 실제로 이어붙인
폴리라인으로 재면 구간 경계의 이음이 섞여 97.9m 밀린다.

**지도 쪽 숫자는 앱이 컴파일하는 그 원본으로 낸다.** `Tools/trail-cut.swift` 가
`App/Watching/RouteTrail.swift` 를 그대로 컴파일한다. 계산을 이 스크립트에 옮겨
적으면 스크립트가 자기 사본을 시험하게 된다.

옛 계산도 같은 표에 찍는다. 고친 것이 무엇이었는지 숫자로 남아야 한다 —
  카드(옛) = totalMeters - remainingMeters   ← 이탈하면 앞으로 튄다
  지도(옛) = 좌표열에서 귀가자에게 가장 가까운 점  ← GPS 가 흔들리면 되돌아간다

서버는 띄우지 않는다. `homecoming_server` 를 그대로 import 해서 임시 DB 에
붙이고 `recompute()` 를 직접 부른다 — HTTP 를 지나갈 이유가 없다.
"""

import json
import os
import pathlib
import subprocess
import sys
import tempfile
from datetime import timedelta

ROOT = pathlib.Path(__file__).resolve().parent.parent
ROUTE = ROOT / "Tools" / "routes" / "commute-sample.json"

os.environ["HOMECOMING_DB"] = str(pathlib.Path(tempfile.mkdtemp()) / "verify.sqlite")
sys.path.insert(0, str(ROOT / "Server"))

import homecoming_server as hs   # noqa: E402


def build_trail_cut():
    """`RouteTrail.swift` 를 컴파일한다. 앱이 쓰는 원본 그대로다."""
    out = pathlib.Path(tempfile.mkdtemp()) / "trail-cut"
    subprocess.run(
        ["swiftc", "-O", str(ROOT / "Tools" / "trail-cut.swift"),
         str(ROOT / "App" / "Watching" / "RouteTrail.swift"), "-o", str(out)],
        check=True)
    return out


def trail_cut(binary, segments, cuts, spots):
    payload = json.dumps({"segments": segments, "cuts": cuts, "spots": spots})
    done = subprocess.run([str(binary)], input=payload, capture_output=True,
                          text=True, check=True)
    return json.loads(done.stdout)


def server_metric(segments, cut):
    """지도가 자른 자리를 **서버의 자로** 되잰다.

    `RouteTrail` 이 돌려주는 `passed` 는 앱이 자기 자(`CLLocation.distance`)로 잰
    값이라 요청한 거리와 같은 것이 당연하다 — 그걸 견주면 아무것도 확인되지
    않는다. 자른 **자리**를 서버가 쓰는 자(`haversine`, 구간별 누적)로 다시 재야
    두 화면이 같은 지점을 가리키는지 나온다.

    `segment`·`passedCount` 는 자른 자리를 다시 짚는 데 필요하다 — 지나온 쪽
    좌표열은 `points[0...index] + [자른 점]` 이므로 꼭짓점 수가 `passedCount - 1` 이다.
    """
    index = cut["segment"]
    walked = 0.0
    for points in segments[:index]:
        walked += sum(hs.haversine(a[0], a[1], b[0], b[1])
                      for a, b in zip(points, points[1:]))
    passed = segments[index][:max(0, cut["passedCount"] - 1)] + [[cut["lat"], cut["lon"]]]
    walked += sum(hs.haversine(a[0], a[1], b[0], b[1])
                  for a, b in zip(passed, passed[1:]))
    return walked


def main():
    route = json.loads(ROUTE.read_text(encoding="utf-8"))
    legs = route["legs"]
    home = route["home"]

    hs.db().execute(
        """INSERT INTO routes (id, account_id, name, home_lat, home_lon, home_radius,
           home_name, total_seconds, legs, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)""",
        ("r1", "acct", route["name"], home["lat"], home["lon"], home["radius"],
         home["name"], route["totalSeconds"], json.dumps(legs), hs.iso(hs.now())))
    started = hs.now()
    hs.db().execute(
        """INSERT INTO sessions (id, traveler, traveler_name, home_lat, home_lon,
           home_radius, home_name, total_meters, remaining_meters, stage, transport,
           expected_arrival, started_at, route_id, measured_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        ("s1", "acct", "아빠", home["lat"], home["lon"], home["radius"], home["name"],
         hs.route_length(legs), hs.route_length(legs), "leaving", "walk",
         hs.iso(started), hs.iso(started), "r1", hs.iso(started)))
    hs.db().commit()

    # 노선도의 분모. 카드는 이 자로 잰다(`RouteShape.totalMeters`).
    shape_total = sum(s["meters"] for s in hs.route_stops(legs))
    geometry = hs.route_geometry(legs)

    def session():
        return hs.db().execute("SELECT * FROM sessions WHERE id = 's1'").fetchone()

    def step(lat, lon, seconds):
        """위치 하나를 흘려 넣고 그때의 상태를 돌려준다."""
        hs.recompute(session(), lat, lon, started + timedelta(seconds=seconds))
        return hs.content_state(session())

    rows = []

    def note(label, state, lat, lon):
        rows.append({
            "label": label, "lat": lat, "lon": lon,
            "travelled": state.get("travelledMeters"),
            "remaining": state["remainingMeters"],
            "source": state.get("estimateSource"),
        })

    # --- 정상 이동 8지점 --------------------------------------------------
    #
    # 파일의 `fixes` 는 실제 퇴근 한 번을 45초 간격으로 적어 둔 것이다. 전부
    # 흘려 넣고 그중 8지점에서 값을 본다 — 진행이 쌓여야 하므로 건너뛰지 않는다.
    fixes = route["fixes"]
    marks = {int(i * (len(fixes) - 1) / 7) for i in range(8)}
    for index, fix in enumerate(fixes):
        state = step(fix["lat"], fix["lon"], fix["t"])
        if index in marks:
            note(f"정상 {index * 100 // (len(fixes) - 1):3d}%", state, fix["lat"], fix["lon"])

    # 마지막 fix 는 집이다. 도착 상태를 따로 본다.
    note("도착", hs.content_state(session()), fixes[-1]["lat"], fixes[-1]["lon"])

    # --- 예외 상황 --------------------------------------------------------
    #
    # 도착한 세션으로는 이어서 잴 수 없으므로(단계가 뒤로 안 간다) 새 세션을
    # 만든다. 60% 지점까지 몰고 가서 세 가지를 시험한다.
    hs.db().execute("DELETE FROM sessions")
    hs.db().execute("DELETE FROM fixes")
    hs.db().execute(
        """INSERT INTO sessions (id, traveler, traveler_name, home_lat, home_lon,
           home_radius, home_name, total_meters, remaining_meters, stage, transport,
           expected_arrival, started_at, route_id, measured_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        ("s1", "acct", "아빠", home["lat"], home["lon"], home["radius"], home["name"],
         hs.route_length(legs), hs.route_length(legs), "leaving", "walk",
         hs.iso(started), hs.iso(started), "r1", hs.iso(started)))
    hs.db().commit()

    sixty = int(len(fixes) * 0.60)
    forty_five = int(len(fixes) * 0.45)
    for fix in fixes[:sixty + 1]:
        state = step(fix["lat"], fix["lon"], fix["t"])
    here = fixes[sixty]
    note("60% 지점", state, here["lat"], here["lon"])

    # GPS 역행 — 45% 자리를 보고한다. 사람은 되돌아가지 않았다.
    back = fixes[forty_five]
    state = step(back["lat"], back["lon"], here["t"] + 45)
    note("GPS 역행", state, back["lat"], back["lon"])

    # 이탈 — 경로에서 1.5km 옆. 위도 0.0135° ≈ 1.5km.
    off = (here["lat"] + 0.0135, here["lon"])
    state = step(off[0], off[1], here["t"] + 90)
    note("이탈 1.5km", state, off[0], off[1])

    # 복귀 — 같은 자리로 돌아온다.
    state = step(here["lat"], here["lon"], here["t"] + 135)
    note("복귀", state, here["lat"], here["lon"])

    # --- 지도 쪽 숫자 -----------------------------------------------------
    binary = build_trail_cut()
    measured = trail_cut(
        binary,
        segments=[s["points"] for s in geometry["segments"]],
        cuts=[float(r["travelled"] if r["travelled"] is not None else 0) for r in rows],
        spots=[[r["lat"], r["lon"]] for r in rows])

    print(f"경로 {ROUTE.name} — 정류장 합 {shape_total}m, "
          f"구간 좌표열 합 {measured['total']:.0f}m "
          f"(지도가 자르는 축. 차이 {measured['total'] - shape_total:+.0f}m)")
    print()
    print("상황          카드(m)   지도(m)    차이 │  카드(옛)   지도(옛)     차이 │ source")
    print("─" * 92)
    lines = [s["points"] for s in geometry["segments"]]
    for row, cut, spot in zip(rows, measured["cuts"], measured["spots"]):
        card = min(max(row["travelled"], 0), shape_total)
        old_card = shape_total - row["remaining"]
        # 지도가 자른 자리를 서버 자로 되잰다. 앱이 돌려준 길이가 아니다.
        here = server_metric(lines, cut)
        print(f"{row['label']:<12} {card:8d} {here:9.0f} {here - card:7.1f} │"
              f" {old_card:9d} {spot['travelled']:10.0f} {spot['travelled'] - old_card:8.0f} │"
              f" {row['source']}")


# ---------------------------------------------------------------- 축 훑기


def sweep(binary, label, legs, steps=60):
    """진행도를 처음부터 끝까지 훑으며 카드와 지도가 갈라지는지 본다.

    8지점만 보면 **구간 경계와 짧은 구간을 지나칠 수 있다.** 78m 짜리 도보 구간은
    보고 한 번에 통째로 지나가고, 자를 자리가 구간 끝에 딱 맞으면 토막 하나가
    점 하나가 된다(그리면 선이 아니다). 그런 자리는 훑어야 나온다.

    카드 쪽은 서버 진행도를 그대로 쓰므로(양 끝만 자른다) 여기서 재는 것은
    **지도가 같은 축에서 같은 자리를 자르는지**다.
    """
    total_seconds = max(leg["startsAt"] + leg["seconds"] for leg in legs)
    length = hs.route_length(legs)
    cuts = []
    for i in range(steps + 1):
        progress = int(total_seconds * i / steps)
        cuts.append(float(max(0, length - hs.route_remaining(legs, progress))))
    # 구간 경계에 정확히 떨어지는 자리도 넣는다. 반쯤 지난 구간이 없는 경우다.
    walked = 0.0
    for segment in hs.route_geometry(legs)["segments"]:
        walked += sum(hs.haversine(a[0], a[1], b[0], b[1])
                      for a, b in zip(segment["points"], segment["points"][1:]))
        cuts.append(walked)

    lines = [s["points"] for s in hs.route_geometry(legs)["segments"]]
    measured = trail_cut(binary, lines, cuts, [])
    server_length = sum(sum(hs.haversine(a[0], a[1], b[0], b[1])
                            for a, b in zip(points, points[1:])) for points in lines)
    worst = 0.0
    for cut, got in zip(cuts, measured["cuts"]):
        # 경로 끝을 넘는 자리는 끝에 붙는다. 그건 어긋남이 아니다.
        expected = min(cut, server_length)
        worst = max(worst, abs(server_metric(lines, got) - expected))
    sweep.last = (lines, measured)
    print(f"  {label:<28} 자리 {len(cuts):3d}개 · 최대 차이 {worst:5.1f}m · "
          f"길이 {measured['total']:8.0f}m")
    return worst


def joined_legs(gap_meters):
    """구간 경계에 일부러 틈을 둔 경로. **축이 경로 모양에 안 매이는지 본다.**

    실제 경로의 이음은 31.8~52.1m 였다(버스가 세워 준 자리와 걸어 나가는 자리가
    다르다). 그것보다 크게 벌려도 지도가 안 밀려야 한다 — 이어붙인 폴리라인으로
    누적하면 여기서 그 틈만큼 어긋난다.
    """
    step = 0.0090          # 위도 1도 ≈ 111km → 약 1km
    jump = gap_meters / 111_000
    legs = []
    lat = 37.5000
    for index in range(6):
        start = lat + (jump if index else 0)
        points = [[round(start + step * k / 4, 5), 126.9000] for k in range(5)]
        legs.append({"mode": "bus" if index % 2 else "walk", "toName": f"{index}번",
                     "startsAt": index * 600, "seconds": 600, "points": points})
        lat = points[-1][0]
    return legs


def short_leg_legs():
    """78m 짜리 구간과 점 하나뿐인 구간이 섞인 경로.

    실제 경로에 둘 다 있다 — `풍산역 정류장` 이 78m 고, 대기 구간은 점이 하나다.
    점 하나짜리 구간은 `route_geometry` 가 좌표열에서 빼므로(선이 아니다) 누적에서
    빠지는데, 서버 `leg_length` 도 0 으로 재니 양쪽이 같아야 한다.
    """
    return [
        {"mode": "walk", "toName": "짧은 도보", "startsAt": 0, "seconds": 120,
         "points": [[37.50000, 126.90000], [37.50035, 126.90035], [37.50070, 126.90070]]},
        {"mode": "wait", "toName": None, "startsAt": 120, "seconds": 180,
         "points": [[37.50070, 126.90070]]},
        {"mode": "subway", "toName": "먼 역", "startsAt": 300, "seconds": 1800,
         "points": [[37.50070, 126.90070], [37.60000, 126.85000], [37.67000, 126.80000]]},
        {"mode": "walk", "toName": "집", "startsAt": 2100, "seconds": 180,
         "points": [[37.67000, 126.80000], [37.67050, 126.80050]]},
    ]


def check_line(label, lines, measured):
    """지도에 **실제로 넘기는 선**을 검사한다.

    자르는 자리가 맞아도 선이 틀리면 화면은 틀린 그림을 그린다. 넷을 본다 —

      잃은 거리   지나온 + 남은 이 구간 길이와 같은가. 다르면 선이 끊긴다
      나눈 점     두 토막이 자른 점을 함께 갖는가. 아니면 그 자리에 틈이 보인다
      한 점 토막  점 하나짜리 토막은 뷰가 안 그린다(`MapPolyline` 에 점 하나는
                  선이 아니다). 그 자리에 길이가 있으면 그만큼 사라진다
      토막 수     구간 안에서 잘렸으면 그 구간만 둘, 나머지는 하나여야 한다
    """
    worst_lost = 0.0
    worst_dropped = 0.0
    gaps = 0
    for cut in measured["cuts"]:
        for points, part in zip(lines, cut["parts"]):
            length = sum(hs.haversine(a[0], a[1], b[0], b[1])
                         for a, b in zip(points, points[1:]))
            # 앱 자로 잰 값이라 자 차이만큼은 벌어진다. 그것까지 걸러내지 않는다.
            worst_lost = max(worst_lost, abs((part["pl"] + part["rl"]) - length)
                             - length * 0.0011)
            if not part["shared"]:
                gaps += 1
            # 그려지지 않는 토막(점 0~1개)에 길이가 남아 있으면 그만큼 안 그려진다.
            if part["p"] < 2:
                worst_dropped = max(worst_dropped, part["pl"])
            if part["r"] < 2:
                worst_dropped = max(worst_dropped, part["rl"])
    ok = "OK" if gaps == 0 and worst_lost < 1.0 and worst_dropped < 1.0 else "실패"
    print(f"  {label:<28} 잃은 거리 {max(0.0, worst_lost):4.1f}m · 틈 {gaps}곳 · "
          f"안 그려진 길이 {worst_dropped:4.1f}m · {ok}")
    return gaps == 0 and worst_lost < 1.0 and worst_dropped < 1.0


def sweeps():
    """`main()` 이 끝에 부른다. 축이 이 경로 하나에만 맞는 것이 아님을 보인다."""
    binary = build_trail_cut()
    legs = json.loads(ROUTE.read_text(encoding="utf-8"))["legs"]
    print()
    print("축 훑기 — 진행도를 처음부터 끝까지 옮기며 지도가 자르는 자리를 견준다")
    cases = [
        ("실제 경로 28.4km", legs),
        ("이음 200m 를 낸 경로", joined_legs(200)),
        ("이음 1000m 를 낸 경로", joined_legs(1000)),
        ("78m 구간 + 점 하나 구간", short_leg_legs()),
    ]
    worst, drawn = [], []
    for label, case in cases:
        worst.append(sweep(binary, label, case))
        drawn.append((label,) + sweep.last)
    print(f"\n  전체 최대 차이 {max(worst):.1f}m — 자 차이다(앱 측지선 · 서버 구)")

    print()
    print("지도에 넘기는 선 — 잘린 좌표열이 온전한지")
    good = all(check_line(label, lines, measured) for label, lines, measured in drawn)
    print(f"\n  {'전부 온전하다' if good else '문제 있다 — 위 줄을 보라'}")


if __name__ == "__main__":
    main()
    sweeps()
