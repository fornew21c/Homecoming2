#!/usr/bin/env python3
"""실제 도로 경로를 재생 가능한 귀가 경로 파일로 만든다.

MapKit 이 준 도로 좌표열(Tools/route-dump.swift)을 받아, 실제 귀가에서
일어나는 일들을 얹는다. 신호 대기, GPS 튐, 터널에서 위치 끊김, 집을
지나쳐서 돌아오기.

    # 강남역 → 서울시청, 45초 간격
    python3 Tools/route-make.py --from 37.4979,127.0276 --to 37.5665,126.9780 \
        --name 지하철-도보 --out Tools/routes/subway-walk.json

    # 신호 대기와 GPS 튐을 섞는다
    python3 Tools/route-make.py --from ... --to ... \
        --stops 300:60,720:45 --jitter 40 --out Tools/routes/stoplights.json

경로를 파일로 저장하는 이유는 셋이다. MapKit 을 매번 부르면 느리고,
네트워크에 의존하고, 결과가 매번 달라져서 회귀 테스트가 안 된다.

의존성 없음.
"""

import argparse
import json
import math
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DUMPER_SOURCE = os.path.join(HERE, "route-dump.swift")
DUMPER_BINARY = os.path.join(HERE, ".route-dump")   # 생성물. 커밋하지 않는다.


def haversine(lat1, lon1, lat2, lon2):
    radius = 6_371_000
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * radius * math.asin(math.sqrt(a))


def straight_leg(origin, destination, spacing=200.0):
    """직선 구간. 지하철에 쓴다 — 지하철은 도로를 따르지 않고 곧게 간다.

    MapKit 은 대중교통 좌표열을 주지 않는다(애플이 transit 폴리라인을 제공하지
    않는다). 그래서 지하철은 역 좌표를 직선으로 잇는다. 실제와 가깝다.
    """
    span = haversine(*origin, *destination)
    steps = max(int(span / spacing), 1)
    points = []
    for i in range(steps + 1):
        ratio = i / steps
        points.append([origin[0] + (destination[0] - origin[0]) * ratio,
                       origin[1] + (destination[1] - origin[1]) * ratio])
    # 지하철 표정속도 약 30km/h (정차 포함)
    return {"points": points, "distance": span, "seconds": max(int(span / 8.3), 60)}


def ensure_dumper():
    """추출기가 없거나 낡았으면 컴파일한다."""
    stale = (not os.path.exists(DUMPER_BINARY)
             or os.path.getmtime(DUMPER_BINARY) < os.path.getmtime(DUMPER_SOURCE))
    if stale:
        print("  경로 추출기 컴파일...", file=sys.stderr)
        subprocess.run(["swiftc", "-O", "-o", DUMPER_BINARY, DUMPER_SOURCE],
                       check=True, capture_output=True)


def road_route(origin, destination, mode):
    """MapKit 으로 실제 도로 경로를 뽑는다."""
    ensure_dumper()
    result = subprocess.run(
        [DUMPER_BINARY, "route", str(origin[0]), str(origin[1]),
         str(destination[0]), str(destination[1]), mode],
        capture_output=True, text=True, timeout=120,
    )
    if result.returncode != 0:
        raise SystemExit(f"경로를 못 뽑았다: {result.stderr.strip() or '알 수 없는 실패'}")
    return json.loads(result.stdout.splitlines()[0])


def geocode(query):
    """장소 이름 → 좌표. 좌표를 손으로 찍지 않으려고 둔다."""
    ensure_dumper()
    result = subprocess.run([DUMPER_BINARY, "geocode", query],
                            capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise SystemExit(f"'{query}' 를 못 찾았다: {result.stderr.strip()}")
    found = json.loads(result.stdout.splitlines()[0])["results"]
    return found


def cumulative(points):
    """좌표열의 누적 거리."""
    out = [0.0]
    for i in range(1, len(points)):
        out.append(out[-1] + haversine(*points[i - 1], *points[i]))
    return out


def at_distance(points, marks, target):
    """경로 위 target 미터 지점의 좌표. 두 점 사이는 선형 보간한다."""
    if target <= 0:
        return points[0]
    if target >= marks[-1]:
        return points[-1]
    for i in range(1, len(marks)):
        if marks[i] >= target:
            span = marks[i] - marks[i - 1]
            ratio = 0 if span == 0 else (target - marks[i - 1]) / span
            lat = points[i - 1][0] + (points[i][0] - points[i - 1][0]) * ratio
            lon = points[i - 1][1] + (points[i][1] - points[i - 1][1]) * ratio
            return [lat, lon]
    return points[-1]


LEG_LABEL = {"walk": "도보", "bus": "버스", "subway": "지하철", "car": "자동차"}


# 모드별 기본 수평 정확도(m). 앱은 200m 를 넘는 위치를 버린다
# (App/Location/HomecomingLocationTracker.swift:236).
DEFAULT_ACCURACY = {"walk": 12, "bus": 30, "car": 30, "subway": 150}


def build_legs(specs, interval, jitter, stations):
    """구간 목록을 위치 열로 만든다.

    구간 문법 — `모드:출발lat,lon:도착lat,lon[:소요초[:정확도m]]` 또는 `wait:초`

        bus:37.49,127.02:37.50,127.03:540        163번 9분
        subway:37.55,126.93:37.65,126.79:1860:150
        wait:240

    **소요초를 직접 주는 게 낫다.** MapKit 은 자동차 속도를 주고, 버스 표정속도를
    상수로 추정하면 실제와 크게 어긋난다. 대중교통 앱이 알려 주는 실측을 그대로 박는다.

    모드마다 다르게 다룬다.
      walk/bus/car  실제 도로 경로
      subway        역 좌표를 직선으로 잇는다 (애플이 대중교통 좌표열을 안 준다)
      wait          환승 대기. 위치는 그대로, 시간만 흐른다

    **지하철에서 위치가 아예 안 오는 게 아니다.** 아이폰은 Wi-Fi 와 셀 기반 측위를
    함께 쓰고, 경의중앙선처럼 지상 구간이 많으면 GPS 도 잡힌다. 문제는 없는 게
    아니라 **부정확한 것**이다. 그래서 정확도를 크게 주고 그만큼 흔든다.
    stations 를 주면 그때만 옛 방식(구간 내내 끊기고 역에서만 잡힘)으로 만든다.
    """
    fixes = []
    legs = []           # 구간 형상과 소요시간. 서버가 이걸로 구간을 판정하고 지연을 잰다.
    clock = 0
    last = None

    for spec in specs:
        parts = spec.split(":")
        mode = parts[0]

        if mode == "wait":
            howlong = int(parts[1])
            legs.append({"mode": "wait", "label": "환승 대기",
                         "startsAt": clock, "seconds": howlong,
                         "points": [last] if last else []})
            clock += howlong
            if last:
                fixes.append({"t": clock, "lat": last[0], "lon": last[1],
                              "acc": DEFAULT_ACCURACY.get("walk", 12),
                              "note": f"환승 대기 {howlong // 60}분"})
            continue

        origin = [float(x) for x in parts[1].split(",")]
        destination = [float(x) for x in parts[2].split(",")]
        label = LEG_LABEL.get(mode, mode)
        given_seconds = int(parts[3]) if len(parts) > 3 and parts[3] else None
        accuracy = float(parts[4]) if len(parts) > 4 and parts[4] else DEFAULT_ACCURACY.get(mode, 30)
        # 도착 지점 이름. 가족 카드가 "풍산역까지 12분" 을 말할 수 있게 하는 값이다.
        to_name = parts[5] if len(parts) > 5 and parts[5] else None

        if mode == "subway":
            leg = straight_leg(origin, destination)
        else:
            leg = road_route(origin, destination, "walking" if mode == "walk" else "automobile")

        if given_seconds:
            leg["seconds"] = given_seconds

        points = leg["points"]
        marks = cumulative(points)
        road = marks[-1]
        pace = road / max(leg["seconds"], 30)

        source = "실측" if given_seconds else "MapKit"
        print(f"  {label:6s} {road:7.0f}m · {leg['seconds']:4d}초 · {pace * 3.6:5.1f}km/h"
              f" · 정확도 {accuracy:.0f}m · {source}", file=sys.stderr)

        # 형상을 남긴다. 위치가 들어오면 서버가 "어느 구간인가" 를 이걸로 판정하고,
        # 그 구간의 기대 시각과 실제 시각의 차이가 지연이다.
        legs.append({
            "mode": mode, "label": label, "toName": to_name,
            "startsAt": clock, "seconds": leg["seconds"],
            "meters": round(road), "accuracy": accuracy,
            "points": [[round(p[0], 6), round(p[1], 6)] for p in points],
        })

        # 옛 방식: 구간 내내 끊기고 역에서만 잡힌다. 실제보다 심하게 잡은 것이다.
        if mode == "subway" and stations:
            fixes.append({"t": clock, "lat": round(points[0][0], 6), "lon": round(points[0][1], 6),
                          "acc": accuracy, "note": f"{label} 승차 — 여기서 위치가 끊긴다"})
            for i in range(1, stations + 1):
                ratio = i / (stations + 1)
                spot = at_distance(points, marks, road * ratio)
                fixes.append({"t": clock + int(leg["seconds"] * ratio),
                              "lat": round(spot[0], 6), "lon": round(spot[1], 6),
                              "acc": accuracy, "note": f"{label} 역 진입"})
            clock += leg["seconds"]
            fixes.append({"t": clock, "lat": round(points[-1][0], 6), "lon": round(points[-1][1], 6),
                          "acc": accuracy, "note": f"{label} 하차 — 위치 복귀"})
            last = points[-1]
            continue

        # 흔들림은 정확도만큼 준다. 정확도 150m 면 그 정도로 튄다.
        shake = jitter if jitter else accuracy

        travelled = 0.0
        while travelled < road:
            lat, lon = at_distance(points, marks, travelled)
            if shake:
                lat += random.gauss(0, shake) / 111_320
                lon += random.gauss(0, shake) / (111_320 * math.cos(math.radians(lat)))
            fixes.append({"t": clock, "lat": round(lat, 6), "lon": round(lon, 6),
                          "acc": accuracy, "note": label})
            travelled += pace * interval
            clock += interval

        fixes.append({"t": clock, "lat": round(points[-1][0], 6), "lon": round(points[-1][1], 6),
                      "acc": accuracy, "note": f"{label} 종료"})
        last = points[-1]

    return fixes, legs


def parse_pairs(raw):
    """"300:60,720:45" → [(300, 60), (720, 45)]"""
    if not raw:
        return []
    out = []
    for chunk in raw.split(","):
        left, right = chunk.split(":")
        out.append((int(left), int(right)))
    return out


def build_single(args, home):
    """한 구간짜리 경로. 신호 대기·GPS 튐·되돌아오기를 얹는다."""
    origin = [float(x) for x in args.origin.split(",")]
    destination = [float(x) for x in args.destination.split(",")]

    route = road_route(origin, destination, args.mode)
    points = route["points"]
    marks = cumulative(points)
    road = marks[-1]
    seconds = max(route["seconds"], 60)
    pace = road / seconds                      # m/초

    print(f"  도로 {road:.0f}m · {seconds}초 · 좌표 {len(points)}개 · {pace * 3.6:.1f}km/h",
          file=sys.stderr)

    stops = dict(parse_pairs(args.stops))

    fixes = []
    travelled = road * min(max(args.start_at, 0.0), 0.95)
    clock = 0
    frozen = 0                                  # 정지로 흘려보낸 시간

    while travelled < road:
        elapsed = clock + frozen

        # 신호 대기: 시간은 가는데 위치가 그대로다. "멈춰 있음" 판정을 시험한다.
        for when, howlong in list(stops.items()):
            if when <= elapsed:
                frozen += howlong
                del stops[when]
                fixes.append({"t": elapsed, "lat": None, "lon": None,
                              "note": f"정지 {howlong}초"})
                elapsed += howlong

        lat, lon = at_distance(points, marks, travelled)
        if args.jitter:
            # 위도 1도 ≈ 111320m. 경도는 위도에 따라 줄어든다.
            lat += random.gauss(0, args.jitter) / 111_320
            lon += random.gauss(0, args.jitter) / (111_320 * math.cos(math.radians(lat)))

        fixes.append({"t": elapsed, "lat": round(lat, 6), "lon": round(lon, 6)})
        travelled += pace * args.interval
        clock += args.interval

    # 마지막은 정확히 도착지에 세운다.
    fixes.append({"t": clock + frozen, "lat": points[-1][0], "lon": points[-1][1]})

    if args.return_to_home:
        # 도착지를 지나쳤으니 경로를 거꾸로 밟아 집으로 온다.
        # 남은거리가 늘어나는 구간이 생겨서 단계 후퇴 방지를 시험한다.
        back = road
        clock = fixes[-1]["t"]
        while back > 0:
            back -= pace * args.interval
            clock += args.interval
            spot = at_distance(points, marks, max(back, 0))
            if haversine(spot[0], spot[1], home[0], home[1]) < args.radius * 0.5:
                fixes.append({"t": clock, "lat": home[0], "lon": home[1], "note": "집 도착"})
                break
            fixes.append({"t": clock, "lat": round(spot[0], 6), "lon": round(spot[1], 6),
                          "note": "되돌아옴"})

    source = {
        "from": origin, "to": destination, "mode": args.mode,
        "roadMeters": round(road), "roadSeconds": seconds,
        "straightMeters": round(haversine(*points[0], *points[-1])),
    }
    return fixes, source


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--leg", action="append", default=[], metavar="구간",
                        help="'모드:출발lat,lon:도착lat,lon' 또는 'wait:초'. "
                             "모드는 walk|bus|subway|car. 여러 번 쓴다. "
                             "쓰면 --from/--to 를 대신한다")
    parser.add_argument("--subway-stations", type=int, default=0,
                        help="지하철 구간에서 역마다 위치가 잡히는 횟수. 0 이면 내내 끊긴다")
    parser.add_argument("--from", dest="origin", help="출발 lat,lon (한 구간짜리)")
    parser.add_argument("--to", dest="destination", help="도착 lat,lon (한 구간짜리)")
    parser.add_argument("--home", help="집 좌표. 없으면 도착지가 집이다")
    parser.add_argument("--radius", type=int, default=120, help="도착 반경(m). 서버 하한 100")
    parser.add_argument("--mode", default="automobile", choices=["automobile", "walking"])
    parser.add_argument("--name", required=True)
    parser.add_argument("--note", default="")
    parser.add_argument("--out", required=True)

    parser.add_argument("--interval", type=int, default=45, help="위치 간격(초)")
    parser.add_argument("--start-at", type=float, default=0.0,
                        help="경로의 몇 %% 지점부터 출발. 짧은 귀가를 만들 때 쓴다")
    parser.add_argument("--jitter", type=float, default=0.0,
                        help="GPS 튐 크기(m). 터널·건물 사이를 흉내낸다")
    parser.add_argument("--stops", default="",
                        help="'경과초:정지초' 목록. 신호 대기·환승")
    parser.add_argument("--gap", default="",
                        help="'경과초:끊긴초'. 지하철 터널에서 위치가 안 온다")
    parser.add_argument("--return-to-home", action="store_true",
                        help="도착지를 지나친 뒤 집으로 되돌아온다. 남은거리가 늘어나는 구간이 생긴다")
    parser.add_argument("--expect-stage", default="arrived")
    parser.add_argument("--expect-correction", choices=["true", "false"], default="true")
    parser.add_argument("--seed", type=int, default=7, help="튐을 재현 가능하게")
    args = parser.parse_args()

    random.seed(args.seed)
    gaps = parse_pairs(args.gap)

    legs = []
    if args.leg:
        tail = [p for p in args.leg if not p.startswith("wait:")][-1].split(":")[2]
        home = [float(x) for x in (args.home or tail).split(",")]
        fixes, legs = build_legs(args.leg, args.interval, args.jitter, args.subway_stations)
        source = {"legs": args.leg}
    elif args.origin and args.destination:
        home = [float(x) for x in
                (args.home or args.destination).split(",")]
        fixes, source = build_single(args, home)
    else:
        raise SystemExit("--leg 을 쓰거나 --from/--to 를 줘라")

    # ------------------------------------------------------------------ 끊김
    for start, howlong in gaps:
        fixes = [f for f in fixes if not (start <= f["t"] < start + howlong)]
        for fix in fixes:
            if fix["t"] >= start + howlong:
                fix["note"] = (fix.get("note") or "") + f" 끊김 {howlong}초 뒤 복귀"
                break

    # 정지 표시(좌표 없음)는 재생기가 못 쓴다. 앞 좌표를 그대로 물려준다.
    cleaned = []
    for fix in fixes:
        if fix["lat"] is None:
            if not cleaned:
                continue
            fix["lat"], fix["lon"] = cleaned[-1]["lat"], cleaned[-1]["lon"]
        cleaned.append(fix)
    fixes = cleaned

    document = {
        "name": args.name,
        "note": args.note,
        "source": source,
        "home": {"lat": home[0], "lon": home[1], "name": "집", "radius": args.radius},
        # 이 경로를 타면 얼마나 걸리는가. 대중교통 앱이 알려 주는 그 값이다.
        # **도착예정은 계산할 게 아니라 이 값이다.** 위치는 어느 구간인지 확인하고
        # 얼마나 밀렸는지 재는 데만 쓴다.
        "totalSeconds": legs[-1]["startsAt"] + legs[-1]["seconds"] if legs else (
            fixes[-1]["t"] if fixes else 0),
        "legs": legs,
        "expect": {
            "stage": args.expect_stage,
            "correction": args.expect_correction == "true",
        },
        "fixes": fixes,
    }

    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(document, handle, ensure_ascii=False, indent=1)
        handle.write("\n")

    total = fixes[-1]["t"]
    print(f"  {args.out} · 위치 {len(fixes)}건 · 모사 {total // 60}분 {total % 60}초",
          file=sys.stderr)


if __name__ == "__main__":
    main()
