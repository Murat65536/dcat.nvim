#!/usr/bin/env python3
# Stand-in for dcat. Logs how it was started and how it ended to $FAKE_DCAT_LOG,
# and draws placeholder frames in the output mode it was given.

import json, os, select, signal, sys, time, tty

args = sys.argv[1:]


def log(event, **fields):
    path = os.environ.get("FAKE_DCAT_LOG")
    if path:
        with open(path, "a") as f:
            f.write(json.dumps({"event": event, "pid": os.getpid(), **fields}) + "\n")


def value(flag, default):
    return args[args.index(flag) + 1] if flag in args else default


if "--version" in args:
    print("dcat " + os.environ.get("FAKE_DCAT_VERSION", "1.4.0"))
    sys.exit(0)
if "--detect-output" in args:
    print(os.environ.get("FAKE_DCAT_OUTPUT", "truecolor"))
    sys.exit(0)

path = args[args.index("--") + 1] if "--" in args else args[-1]
if "broken" in path:
    log("start", args=args)
    print(f'dcat: No suitable reader found for the file format of file "{path}".')
    sys.exit(1)

mode = "kitty" if "--kitty" in args else "sixel" if "--sixel" in args else "characters"
cell_width, cell_height = map(int, value("--cell-size", "10x20").split("x"))
image_id = value("--kitty-image-id", "1")


def quit(reason):
    log("exit", reason=reason)
    sys.exit(0)


for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
    signal.signal(sig, lambda number, _: quit(signal.Signals(number).name))
signal.signal(signal.SIGWINCH, lambda *_: draw())


# With $FAKE_DCAT_FIXED_SIZE, frames keep the starting size, like frames
# rendered before a resize
fixed_size = os.get_terminal_size(1) if os.environ.get("FAKE_DCAT_FIXED_SIZE") else None


def draw():
    columns, rows = fixed_size or os.get_terminal_size(1)
    out = "\x1b[?2026h\x1b[H"
    if mode == "kitty":
        out += f"\x1b_Ga=T,f=32,s={columns * cell_width},v={rows * cell_height},i={image_id},p=1,q=2,C=1;AAAA\x1b\\"
    elif mode == "sixel":
        out += f'\x1bPq"1;1;{columns * cell_width};{(rows - 1) * cell_height}#0~\x1b\\'
    else:
        out += "fake dcat frame"
    os.write(1, (out + "\x1b[?2026l").encode())


if os.isatty(0):
    tty.setraw(0)
# Logged once keys and signals are handled, so tests can wait for it
log("start", args=args)
while True:
    draw()
    if select.select([0], [], [], 0.1)[0]:
        for key in os.read(0, 64).decode(errors="replace"):
            if key == "q":
                quit("q")
            if key == "\x03":
                quit("ctrl-c")
            log("key", key=key)
