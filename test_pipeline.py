"""Test hors interface du pipeline de résolution."""

from __future__ import annotations

import sys

from xgrab.resolver import ResolutionError, resolve
from xgrab.utils import human_size, human_time, parse_many_urls, parse_template, sanitize_filename


def test_utils() -> None:
    assert sanitize_filename('a<b>c:d"e/f\\g|h?i*j') == "a_b_c_d_e_f_g_h_i_j"
    assert sanitize_filename("  ..con..  ") != ""
    assert sanitize_filename("CON") != "CON"
    assert human_size(1181116006).endswith("Go")
    assert human_time(2365) == "39:25"
    assert human_time(3725) == "1:02:05"
    assert parse_many_urls("voici https://www.youtube.com/watch?v=dQw4w9WgXcQ et http://b.co/c.") == [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "http://b.co/c",
    ]
    assert parse_template("{author}_{id}", {"author": "abc", "id": "42"}) == "abc_42"
    print("utils      OK")


def test_resolver(url: str) -> None:
    info = resolve(url)
    print(f"extracteur : {info.extractor}")
    print(f"titre      : {info.title}")
    print(f"durée      : {info.duration_label}")
    print(f"variantes  : {len(info.variants)}")
    for variant in info.variants:
        print(f"   - {variant.height_label:>7}  {variant.describe()}")
    assert info.variants
    assert info.variants[0].height >= 1080
    heights = [v.height for v in info.variants]
    assert heights == sorted(heights, reverse=True)
    assert any(v.kind == "http" and v.size_known for v in info.variants)
    print("resolver   OK")


def test_resolver_error() -> None:
    try:
        resolve("https://www.youtube.com/watch?v=AAAAAAAAAAA")
    except ResolutionError as exc:
        print(f"erreur gérée proprement : {str(exc)[:70]}")
    else:
        raise AssertionError("devrait lever ResolutionError")


if __name__ == "__main__":
    test_utils()
    test_resolver_error()
    if len(sys.argv) > 1:
        test_resolver(sys.argv[1])
    print("\nTOUT EST PASSE")
