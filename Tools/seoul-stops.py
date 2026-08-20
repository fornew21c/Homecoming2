#!/usr/bin/env python3
"""서울시 버스정류소 위치정보 엑셀을 서버가 읽을 파일로 바꾼다.

    python3 Tools/seoul-stops.py ~/Downloads/서울시버스정류소위치정보*.xlsx

**왜 파일인가** — 서울 시내버스 정류장의 이름과 좌표를 함께 주는 데이터가 여기밖에
없다. 공공데이터포털의 버스정류장 API 는 이름은 주는데 좌표가 없고, TAGO 는 좌표를
주는데 서울 시내버스가 없다. 둘을 이어 붙일 공통 키도 없다.

파일이 API 보다 나은 자리이기도 하다. 요청 제한이 없고, 서버가 뜰 때 한 번 읽어
두면 검색이 즉시 끝난다. 정류장 위치는 자주 바뀌지 않는다.

받는 곳 — 서울 열린데이터광장, 신청도 인증키도 필요 없다.
https://data.seoul.go.kr/dataList/OA-15067/S/1/datasetView.do

의존성 없음. 엑셀을 zip 으로 열어 직접 읽는다.
"""

import json
import os
import pathlib
import re
import sys
import xml.etree.ElementTree as ET
import zipfile

OUT = pathlib.Path(__file__).resolve().parent.parent / "Server" / "data" / "seoul-stops.json"
SHEET_NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"


def cells(book, sheet, shared):
    """시트를 한 줄씩 {열자: 값} 으로 낸다."""
    for _, element in ET.iterparse(book.open(sheet), events=("end",)):
        if element.tag != SHEET_NS + "row":
            continue
        row = {}
        for cell in element.findall(SHEET_NS + "c"):
            column = "".join(ch for ch in cell.get("r") if ch.isalpha())
            value = cell.find(SHEET_NS + "v")
            if value is None:
                continue
            row[column] = shared[int(value.text)] if cell.get("t") == "s" else value.text
        yield row
        element.clear()


def convert(path):
    book = zipfile.ZipFile(path)
    raw = book.read("xl/sharedStrings.xml").decode("utf-8")
    shared = ["".join(re.findall(r"<t[^>]*>(.*?)</t>", chunk, re.S))
              for chunk in re.findall(r"<si>(.*?)</si>", raw, re.S)]

    rows = cells(book, "xl/worksheets/sheet1.xml", shared)
    header = next(rows)
    # 열 위치를 머리글에서 찾는다. 자리로 박아 두면 다음 해 파일에서 조용히 어긋난다.
    where = {name: column for column, name in header.items()}
    for needed in ("정류소명", "X좌표", "Y좌표", "ARS_ID"):
        if needed not in where:
            raise SystemExit(f"'{needed}' 열이 없다. 머리글: {sorted(where)}")

    stops = []
    for row in rows:
        name = (row.get(where["정류소명"]) or "").strip()
        # X 가 경도, Y 가 위도다. 흔한 규약인데 위경도 순서를 쓰는 코드와 섞이면
        # 뒤집기 쉽다 — 실제로 이 변환기를 처음 쓸 때 뒤집었고, 아래 범위 검사가
        # 잡았다. 그래서 그 검사를 남겨 둔다.
        lat = row.get(where["Y좌표"])
        lon = row.get(where["X좌표"])
        if not name or not lat or not lon:
            continue
        try:
            lat, lon = round(float(lat), 6), round(float(lon), 6)
        except ValueError:
            continue
        # 대한민국 밖이면 열이 뒤바뀐 것이다. 조용히 넘기지 않고 세운다.
        if not (33 <= lat <= 39 and 124 <= lon <= 132):
            raise SystemExit(f"좌표가 이상하다: {name} {lat}, {lon} — 열 배치를 확인해라")
        stops.append([name, lat, lon, (row.get(where["ARS_ID"]) or "").strip()])

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as handle:
        json.dump(stops, handle, ensure_ascii=False, separators=(",", ":"))
    return stops


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    made = convert(sys.argv[1])
    size = OUT.stat().st_size
    print(f"  {OUT.relative_to(pathlib.Path.cwd()) if str(OUT).startswith(str(pathlib.Path.cwd())) else OUT}")
    print(f"  정류소 {len(made)}건 · {size / 1024:.0f}KB")
