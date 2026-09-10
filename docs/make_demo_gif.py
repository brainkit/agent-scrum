#!/usr/bin/env python3
"""Render docs/demo.gif: four captions, one card, real output.

A stranger must get it without reading a manual: the agent says the task
is done, its test fails, the card does not move, the bug is fixed, the
card moves. Big caption, three columns, one line of terminal at a time.

The refusal line and every status still come from actually running the
commands — the whole claim of the tool is "it refuses", so a mocked
recording would be worthless.

    python3 docs/make_demo_gif.py [output.gif]
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "docs", "demo.gif")

WIDTH, HEIGHT = 860, 400
BOARD_TOP, BOARD_BOTTOM = 110, 285
LINE_Y = 320

PAGE = (247, 247, 245)
TITLE = (24, 24, 26)
COLUMN_BG = (234, 234, 230)
COLUMN_TEXT = (126, 126, 132)
CARD_BG = (255, 255, 255)
CARD_TEXT = (30, 30, 34)
CARD_EDGE = (205, 205, 201)
RED = (203, 58, 58)
GREEN = (34, 140, 80)
DIM = (128, 128, 134)

COLUMNS = ["CODING", "TESTING", "DONE"]
HOLD_MS = 2200
MOVE_MS = 70
FINAL_MS = 3200


def load_font(size, bold=False, mono=False):
    if mono:
        names = ["/usr/share/fonts/truetype/dejavu/DejaVuSansMono%s.ttf" % ("-Bold" if bold else ""),
                 "/usr/share/fonts/truetype/liberation/LiberationMono-%s.ttf" % ("Bold" if bold else "Regular")]
    else:
        names = ["/usr/share/fonts/truetype/dejavu/DejaVuSans%s.ttf" % ("-Bold" if bold else ""),
                 "/usr/share/fonts/truetype/liberation/LiberationSans-%s.ttf" % ("Bold" if bold else "Regular")]
    for path in names:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


F_CAPTION = load_font(26, bold=True)
F_COLUMN = load_font(13, bold=True)
F_CARD = load_font(17)
F_CARD_SMALL = load_font(12)
F_LINE = load_font(16, mono=True)


def run(cwd, args):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    return (result.stdout + result.stderr).strip()


def capture():
    """Run it for real; keep only the two lines the GIF shows."""
    workdir = tempfile.mkdtemp(prefix="agent-scrum-gif.")
    project = os.path.join(workdir, "demo")
    os.makedirs(os.path.join(project, "src"), exist_ok=True)
    os.makedirs(os.path.join(project, "tests"), exist_ok=True)
    run(project, ["node", os.path.join(REPO, "bin", "init.js"), project, "--yes"])

    crm = ["node", os.path.join(project, "scrum_crm", "crm.mjs")]
    opened = run(project, crm + [
        "fast-open", "Add sum()",
        "Given 2 and 2 When sum(2,2) is called Then it returns 4", "src/sum.js",
    ])
    task_id, agent = opened.split()[0], opened.split()[1]

    with open(os.path.join(project, "src", "sum.js"), "w") as handle:
        handle.write("function sum(a, b) {\n  return a - b;\n}\nmodule.exports = { sum };\n")
    with open(os.path.join(project, "tests", f"task_{task_id}.test.js"), "w") as handle:
        handle.write("const assert = require('node:assert');\n"
                     "const { sum } = require('../src/sum.js');\n"
                     "assert.strictEqual(sum(2, 2), 4);\n")

    refused = re.sub(r"\s*\(log: .*\)", "", run(project, crm + ["fast-close", task_id, agent]).splitlines()[0])
    stayed = run(project, crm + ["db", "--scalar", f"SELECT status FROM tasks WHERE id={task_id}"])

    with open(os.path.join(project, "src", "sum.js"), "w") as handle:
        handle.write("function sum(a, b) {\n  return a + b;\n}\nmodule.exports = { sum };\n")
    closed = run(project, crm + ["fast-close", task_id, agent]).splitlines()[-1]
    final = run(project, crm + ["db", "--scalar", f"SELECT status FROM tasks WHERE id={task_id}"])

    shutil.rmtree(workdir, ignore_errors=True)
    return {"id": task_id, "refused": refused, "stayed": stayed, "closed": closed, "final": final}


def boxes():
    gap, margin = 16, 40
    width = (WIDTH - margin * 2 - gap * (len(COLUMNS) - 1)) / len(COLUMNS)
    return [(margin + index * (width + gap), width) for index in range(len(COLUMNS))]


def render(caption, card_x, card_state, line, line_color):
    image = Image.new("RGB", (WIDTH, HEIGHT), PAGE)
    draw = ImageDraw.Draw(image)
    draw.text((40, 38), caption, font=F_CAPTION, fill=TITLE)

    for (x, width), name in zip(boxes(), COLUMNS):
        draw.rounded_rectangle([x, BOARD_TOP, x + width, BOARD_BOTTOM], 10, fill=COLUMN_BG)
        draw.text((x + 12, BOARD_TOP + 11), name, font=F_COLUMN, fill=COLUMN_TEXT)

    edge = {"normal": CARD_EDGE, "refused": RED, "done": GREEN}[card_state]
    width = boxes()[0][1]
    top = BOARD_TOP + 40
    draw.rounded_rectangle([card_x, top, card_x + width, top + 86], 9, fill=CARD_BG, outline=edge, width=3)
    draw.text((card_x + 14, top + 14), f"#{'1'}", font=F_CARD_SMALL, fill=COLUMN_TEXT)
    draw.text((card_x + 14, top + 34), "Add sum()", font=F_CARD, fill=CARD_TEXT)
    if card_state == "refused":
        draw.text((card_x + 14, top + 60), "✗ tests are red", font=F_CARD_SMALL, fill=RED)
    if card_state == "done":
        draw.text((card_x + 14, top + 60), "✓ tests pass", font=F_CARD_SMALL, fill=GREEN)

    if line:
        draw.text((40, LINE_Y), line, font=F_LINE, fill=line_color)
    return image


def build(data):
    positions = [box[0] for box in boxes()]
    coding_x, done_x = positions[0], positions[-1]
    frames, durations = [], []

    def add(frame, ms):
        frames.append(frame)
        durations.append(ms)

    add(render("The agent says the task is done.", coding_x, "normal",
               "$ finish task 1", DIM), HOLD_MS)
    add(render("Its test fails, so the close is refused.", coding_x, "refused",
               data["refused"].replace(f"task {data['id']}", "task 1"), RED), HOLD_MS + 600)
    add(render(f"The card stays in {data['stayed']}. Nothing moved.", coding_x, "refused",
               "no promise, no exception — a database rule", DIM), HOLD_MS)
    add(render("Fix the bug, finish again.", coding_x, "normal",
               "$ finish task 1", DIM), 1500)

    steps = 12
    for step in range(1, steps + 1):
        add(render("Fix the bug, finish again.", coding_x + (done_x - coding_x) * step / steps,
                   "normal", "$ finish task 1", DIM), MOVE_MS)

    add(render("Now it closes.", done_x, "done", data["closed"].replace(data["id"], "1"), GREEN), HOLD_MS)
    add(render("The rule lives in the database, not in a prompt.", done_x, "done",
               "npx agent-scrum", DIM), FINAL_MS)
    return frames, durations


def main():
    data = capture()
    frames, durations = build(data)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    palette = frames[-1].convert("P", palette=Image.ADAPTIVE, colors=32)
    paletted = [frame.quantize(palette=palette, dither=Image.NONE) for frame in frames]
    paletted[0].save(OUT, save_all=True, append_images=paletted[1:], duration=durations, loop=0, optimize=True)
    frames[1].save(OUT.replace(".gif", "-refused.png"))
    frames[-1].save(OUT.replace(".gif", "-last.png"))
    print(json.dumps({
        "frames": len(frames),
        "seconds": round(sum(durations) / 1000, 1),
        "kb": round(os.path.getsize(OUT) / 1024, 1),
        "size": f"{WIDTH}x{HEIGHT}",
    }))


if __name__ == "__main__":
    main()
