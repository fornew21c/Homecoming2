#!/usr/bin/env python3
"""전국도시철도역사 자료를 지하철 폴리라인용 표로 굽는다.

    python3 Tools/subway-lines.py ~/Downloads/전국도시철도역사정보표준데이터.xlsx

**왜 필요한가.** 지하철 구간은 두 역 좌표를 잇는 직선으로 저장된다. 실제 선로는
직선이 아니라서, 서강대 → 풍산에서 저장된 선이 실제 노선에서 **1,994m** 까지
벌어진다(능곡역, 2026-08-26 실측). 이탈 문턱이 1,000m 라 정상 귀가가 이탈로
오판됐고, 그날 39분을 이탈 상태로 돌았다.

**왜 런타임 API 가 아닌가.** 역 정보는 자주 안 바뀐다. 매번 물어 일일 한도·사내망
TLS·응답 지연을 치를 이유가 없다. `Server/data/seoul-stops.json` 과 같은 판단이다.

**왜 직접 안 받는가.** 레일포털의 파일 주소가 안정적인지 확인하지 못했다. 확인 안 된
주소를 코드에 박으면 어느 날 조용히 빈 파일이 된다. 받는 주소는 설계문서에 있다 —
`docs/superpowers/specs/2026-08-26-subway-polyline-design.md`.

의존성 없음. 서버와 같은 방침이다.
"""

import json
import pathlib
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Server" / "data" / "subway-lines.json"
NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"


def read_sheet(path):
    """XLSX 첫 시트를 {열이름: 값} 목록으로.

    **셀 주소로 읽는다. 위치로 읽으면 안 된다.** XLSX 는 빈 칸을 아예 안 적어서,
    셀을 나온 순서대로 세면 열이 밀린다. 그렇게 읽고 "좌표 없는 행이 661개" 라는
    틀린 값을 한 번 얻었다(2026-08-26). 실제로는 하나도 없다.
    """
    book = zipfile.ZipFile(path)
    shared = [
        "".join(t.text or "" for t in si.iter(f"{NS}t"))
        for si in ET.fromstring(book.read("xl/sharedStrings.xml")).findall(f"{NS}si")
    ]
    rows = []
    for row in ET.fromstring(book.read("xl/worksheets/sheet1.xml")).iter(f"{NS}row"):
        cells = {}
        for cell in row.findall(f"{NS}c"):
            value = cell.find(f"{NS}v")
            column = "".join(ch for ch in cell.get("r", "") if ch.isalpha())
            if value is None:
                cells[column] = ""
            elif cell.get("t") == "s":
                cells[column] = shared[int(value.text)]
            else:
                cells[column] = value.text
        rows.append(cells)
    if not rows:
        return []
    column_of = {name: col for col, name in rows[0].items()}
    return [{name: row.get(col, "") for name, col in column_of.items()} for row in rows[1:]]


def build(rows):
    """노선번호 → {이름, 역[]}. 역은 역번호 순이다.

    **노선명이 아니라 노선번호로 묶는다.** `1호선` 은 서울에도 부산에도 있다.
    이름으로 묶으면 두 도시의 역이 한 노선에 섞이고, 사이 역을 세는 순간 엉뚱한
    좌표가 나온다.

    **노선을 거르지 않는다.** 역번호는 노선 전체가 아니라 블록 안에서만 순서다 —
    경의중앙선은 지선(서울역·신촌)과 옛 코드 블록 때문에 전체를 한 줄로 세우면
    되돌아간다. 그 판단은 구간을 고르는 서버가 한다(`subway_leg_stops`).
    """
    lines = {}
    for row in rows:
        try:
            lat = float(row["역위도"])
            lon = float(row["역경도"])
        except (KeyError, ValueError, TypeError):
            continue
        line = lines.setdefault(row["노선번호"], {"이름": row["노선명"], "역": []})
        line["역"].append({
            "번호": row["역번호"],
            "이름": row["역사명"],
            "lat": round(lat, 6),
            "lon": round(lon, 6),
        })
    for line in lines.values():
        line["역"].sort(key=lambda station: station["번호"])
    return dict(sorted(lines.items()))


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 1
    lines = build(read_sheet(sys.argv[1]))
    stations = sum(len(line["역"]) for line in lines.values())
    OUT.write_text(
        json.dumps(lines, ensure_ascii=False, indent=1, sort_keys=True) + "\n",
        encoding="utf-8")
    print(f"노선 {len(lines)}개 · 역 {stations}개 → {OUT.relative_to(ROOT)} "
          f"({OUT.stat().st_size // 1024}KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
