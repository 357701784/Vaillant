"""
把用户提供的图标转成 iOS 需要的 App 图标。

iOS 要求：
  - 1024x1024 正方形
  - 不带 alpha 通道（必须不透明）
  - PNG 格式

源图是竖版的兔子 logo（179x247），所以做法是：
  裁掉白边 → 等比缩放到 1024 高的正方形画布内居中 → 补白底 → 去掉 alpha

用法：python3 Tools/make_icon.py [源图路径]
"""
import os
import sys
from PIL import Image, ImageChops

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "..", "Resources", "Assets.xcassets",
                        "AppIcon.appiconset")
OUT_PNG = os.path.join(OUT_DIR, "AppIcon-1024.png")
SIZE = 1024

DEFAULT_SRC = os.path.expanduser(
    "~/Downloads/3812b31bb051f8198618a65ab8fb5ded2e738bd449d9.webp")


def content_bbox(im, threshold=12):
    """非白内容的包围盒。"""
    bg = Image.new("RGB", im.size, (255, 255, 255))
    diff = ImageChops.difference(im, bg).convert("L")
    return diff.point(lambda p: 255 if p > threshold else 0).getbbox()


def build(src_path):
    im = Image.open(src_path).convert("RGB")

    # 裁掉白边
    bbox = content_bbox(im)
    if bbox:
        im = im.crop(bbox)
    print(f"裁白边后: {im.size}")

    # 等比缩放，放进 1024 正方形画布居中
    scale = (SIZE * 0.86) / max(im.size)      # 留 7% 边距
    new_size = (max(1, round(im.size[0] * scale)),
                max(1, round(im.size[1] * scale)))
    im = im.resize(new_size, Image.LANCZOS)
    print(f"缩放后: {im.size}")

    canvas = Image.new("RGB", (SIZE, SIZE), (255, 255, 255))
    canvas.paste(im, ((SIZE - im.size[0]) // 2, (SIZE - im.size[1]) // 2))

    # iOS 图标不允许透明通道
    canvas = canvas.convert("RGB")

    os.makedirs(OUT_DIR, exist_ok=True)
    canvas.save(OUT_PNG, "PNG")
    print(f"已生成 {OUT_PNG}  {canvas.size[0]}x{canvas.size[1]}")


if __name__ == "__main__":
    build(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC)
