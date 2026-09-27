"""Record every accelerator operation of one versus_cpu() run, with the
expected result, into ops_trace.txt.  The RTL testbench replays this file.

Line format, five fields, op in decimal and the rest in hex:
    1 key_index key   0             0            LOAD_KEY
    2 0         0     0             0            RESET
    3 pos       color expected_hash 0            MOVE
    4 pos       color expected_hash {fast,cond}  USEFUL
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.join(HERE, 'run_benchmark.py')
OUT = os.path.join(HERE, 'ops_trace.txt')

OP_LOAD_KEY, OP_RESET, OP_MOVE, OP_USEFUL = 1, 2, 3, 4


class Recorder:
    def __init__(self, fh):
        self.fh = fh
        self.counts = {OP_LOAD_KEY: 0, OP_RESET: 0, OP_MOVE: 0, OP_USEFUL: 0}

    def _emit(self, op, a, b, c, d):
        self.counts[op] += 1
        self.fh.write('%d %x %x %016x %x\n' % (op, a, b, c, d))

    def load_key(self, idx, key):
        self._emit(OP_LOAD_KEY, idx, key, 0, 0)

    def reset(self):
        self._emit(OP_RESET, 0, 0, 0, 0)

    def move(self, pos, color, hash_after):
        self._emit(OP_MOVE, pos, color, hash_after, 0)

    def useful(self, pos, color, fast, cond, h):
        self._emit(OP_USEFUL, pos, color, h, (fast << 1) | cond)


def main():
    spec = importlib.util.spec_from_file_location('go_hw', os.path.abspath(BENCH))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    with open(OUT, 'w') as fh:
        rec = Recorder(fh)
        mod.ACCEL.trace = rec
        result = mod.versus_cpu()

    assert result == 5, 'benchmark did not return the expected move 5'
    total = sum(rec.counts.values())
    print('wrote %s' % OUT)
    print('  LOAD_KEY %6d' % rec.counts[OP_LOAD_KEY])
    print('  RESET    %6d' % rec.counts[OP_RESET])
    print('  MOVE     %6d' % rec.counts[OP_MOVE])
    print('  USEFUL   %6d' % rec.counts[OP_USEFUL])
    print('  total    %6d ops' % total)
    return 0


if __name__ == '__main__':
    sys.exit(main())
