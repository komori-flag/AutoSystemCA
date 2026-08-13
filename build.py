#!/usr/bin/env python3
"""Build the AutoSystemCA module zip (deterministic, cross-platform).

Usage:  python build.py
Output: AutoSystemCA.zip
"""
import os
import zipfile

# 打包进 zip 的文件（保持正斜杠相对路径）
FILES = [
    "module.prop",
    "customize.sh",
    "post-fs-data.sh",
    "service.sh",
    "action.sh",
    "certs/README.txt",
    "webroot/index.html",
    "README.md",
    "changelog.md",
]

ZIP_NAME = "AutoSystemCA.zip"


def main() -> None:
    with zipfile.ZipFile(ZIP_NAME, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in FILES:
            if not os.path.isfile(f):
                raise SystemExit(f"missing file: {f}")
            zf.write(f, arcname=f)
    print(f"built {ZIP_NAME} ({os.path.getsize(ZIP_NAME)} bytes)")


if __name__ == "__main__":
    main()
