#!/usr/bin/env python3
"""서울시 버스노선ID 정보 엑셀을 서버가 읽을 파일로 바꾼다.

    python3 Tools/seoul-routes.py ~/Downloads/서울시버스노선ID정보*.xlsx

**왜 필요한가** — 서울시 TOPIS 도착정보는 노선번호(`163`)가 아니라 내부
id(`100100032`)로 묻는다. 그 id 를 주는 `busRouteInfo/getBusRouteList` 는
별도 활용신청이 필요하고 지금 키로는 401 이다(2026-08-26 실측).

**그런데 표로 받으면 신청이 필요 없다.** 서울 열린데이터광장에 노선번호와
id 가 짝지어진 파일이 있다. 정류장 표(`seoul-stops.py`)를 같은 이유로 같은
곳에서 받아 굽고 있다 — 요청 제한이 없고, 서버가 뜰 때 한 번 읽으면 조회가
즉시 끝난다. 노선 id 는 자주 바뀌지 않는다.

받는 곳 — 서울 열린데이터광장, 신청도 인증키도 필요 없다.
https://data.seoul.go.kr

의존성 없음. 엑셀을 zip 으로 열어 직접 읽는다.
"""

import json
import pathlib
import re
import sys
import xml.etree.ElementTree as ET
import zipfile

OUT = pathlib.Path(__file__).resolve().parent.parent / "Server" / "data" / "seoul-routes.json"
SHEET_NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"


def cells(book, sheet, shared):
    """시트를 한 줄씩 {열자: 값} 으로 낸다.

    **셀 주소로 읽는다.** XLSX 는 빈 칸을 아예 안 적어서, 나온 순서대로 세면
    열이 밀린다(2026-08-26 에 지하철 표에서 그렇게 틀린 값을 얻었다).
    """
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
    for needed in ("노선명", "ROUTEID"):
        if needed not in where:
            raise SystemExit(f"'{needed}' 열이 없다. 머리글: {sorted(where)}")

    routes = {}
    for row in rows:
        name = (row.get(where["노선명"]) or "").strip()
        rid = (row.get(where["ROUTEID"]) or "").strip()
        if not name or not rid:
            continue
        # **같은 번호가 여러 id 를 가질 수 있다**(01A/01B 처럼 갈래가 있는 노선).
        # 먼저 나온 것을 쓰되 나머지도 남긴다 — 도착정보를 물었을 때 우리 정류장이
        # 없으면 다음 것을 보면 된다.
        routes.setdefault(name, []).append(rid)

    if not routes:
        raise SystemExit("노선을 하나도 못 읽었다")
    return routes


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    routes = convert(sys.argv[1])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(routes, ensure_ascii=False, separators=(",", ":")),
                   encoding="utf-8")
    many = sum(1 for ids in routes.values() if len(ids) > 1)
    print(f"노선 {len(routes)}개 → {OUT}  ({OUT.stat().st_size // 1024}KB)")
    if many:
        print(f"  id 가 둘 이상인 노선 {many}개")
    for probe in ("163", "6713"):
        print(f"  {probe}: {routes.get(probe, '없음')}")


if __name__ == "__main__":
    main()
