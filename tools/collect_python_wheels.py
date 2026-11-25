"""采集 Python 3.13 运行时所需的 wheel 地址（清华 PyPI 镜像）。

规则：优先 cp313-cp313-win_amd64，其次 cp3x-abi3-win_amd64，纯 Python 包用
py3-none-any；排除预发布（a/b/rc）。安装器只认这里写死的 URL，运行时不查索引。
"""
import json
import re
import urllib.request

PACKAGES = [
    "requests",
    "urllib3",
    "idna",
    "charset-normalizer",
    "certifi",
    "beautifulsoup4",
    "soupsieve",
    "typing-extensions",
    "pyquery",
    "cssselect",
    "lxml",
    "pycryptodome",
    "numpy",
    "pywasm",
]

BASE = "https://pypi.tuna.tsinghua.edu.cn/simple/{}/"
HREF = re.compile(r'href="([^"#]+\.whl)(?:#sha256=([0-9a-f]+))?"')
PRERELEASE = re.compile(r"[ab]|rc")


def split_name(filename):
    parts = filename.split("-")
    return parts[0], parts[1]


def version_tuple(text):
    out = []
    for chunk in re.split(r"[.]", text):
        digits = re.match(r"\d+", chunk)
        out.append(int(digits.group()) if digits else 0)
    return tuple(out)


def pick(pkg, names):
    candidates = []
    for name in names:
        if PRERELEASE.search(split_name(name)[1]):
            continue
        if name.endswith("cp313-cp313-win_amd64.whl"):
            rank = 0
        elif re.search(r"cp3\d-abi3-win_amd64\.whl$", name):
            rank = 1
        elif name.endswith("py3-none-any.whl") or name.endswith("py2.py3-none-any.whl"):
            rank = 2
        else:
            continue
        candidates.append((rank, version_tuple(split_name(name)[1]), name))
    if not candidates:
        return None
    # rank 越小越好；同 rank 取版本最高的（元组加负号实现降序）。
    candidates.sort(key=lambda c: (c[0], tuple(-x for x in c[1])))
    return candidates[0]


def main():
    out = []
    for pkg in PACKAGES:
        html = urllib.request.urlopen(BASE.format(pkg), timeout=60).read().decode("utf-8", "replace")
        entries = {}
        for href, sha in HREF.findall(html):
            entries[href.rsplit("/", 1)[-1]] = (href, sha)
        chosen = pick(pkg, list(entries))
        if chosen is None:
            print(f"MISS {pkg}")
            continue
        _, _, name = chosen
        href, sha = entries[name]
        url = "https://pypi.tuna.tsinghua.edu.cn/" + href.lstrip("./")
        out.append({"name": name, "url": url, "sha256": sha})
        print(f"OK   {name}")
    with open(".wheels.json", "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
