#!/usr/bin/env python3
# Runs a command in a 120x40 pseudo-terminal with 10x20 pixel cells, which
# reports its size in pixels like a graphical terminal and answers device
# attribute queries. Usage: tui.py command...

import fcntl, os, select, struct, subprocess, sys, termios

columns, rows, cell_width, cell_height = 120, 40, 10, 20
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, columns * cell_width, rows * cell_height))


def controlling_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


env = dict(os.environ, TERM="xterm-256color")
child = subprocess.Popen(
    sys.argv[1:], stdin=slave, stdout=slave, stderr=slave, preexec_fn=controlling_terminal, env=env
)
os.close(slave)
while child.poll() is None:
    if select.select([master], [], [], 0.05)[0]:
        try:
            output = os.read(master, 1 << 20)
        except OSError:
            break
        for _ in range(output.count(b"\x1b[c")):
            os.write(master, b"\x1b[?62;22c")
sys.exit(child.wait())
