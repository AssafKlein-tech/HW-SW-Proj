"""After every Board.move() of a real run, check that the accelerator model
still agrees with the Python board on the Zobrist hash, the colour of all 81
points and the partition of stones into groups.  Parent pointers are allowed
to differ (the two sides compress paths at different times); the partition
is the invariant."""
import importlib.util
import os
import sys

BENCH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'run_benchmark.py')


def main():
    spec = importlib.util.spec_from_file_location('go_hw', BENCH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    acc = mod.ACCEL

    bad = {'n': 0, 'hash': 0, 'color': 0, 'groups': 0}
    orig = mod.Board.move

    def move(self, pos):
        orig(self, pos)
        bad['n'] += 1
        if acc.hash != self.zobrist.hash:
            bad['hash'] += 1
        if [s.color for s in self.squares] != acc.color:
            bad['color'] += 1
        sw, hw = {}, {}
        for s in self.squares:
            if s.color:
                sw.setdefault(s.find().pos, set()).add(s.pos)
                hw.setdefault(acc.find(s.pos), set()).add(s.pos)
        if sorted(map(sorted, sw.values())) != sorted(map(sorted, hw.values())):
            bad['groups'] += 1

    mod.Board.move = move
    assert mod.versus_cpu() == 5

    print('Board.move calls checked : %d' % bad['n'])
    print('zobrist hash mismatches  : %d' % bad['hash'])
    print('board colour mismatches  : %d' % bad['color'])
    print('group partition mismatch : %d' % bad['groups'])
    ok = not (bad['hash'] or bad['color'] or bad['groups'])
    print('\n%s' % ('SHADOW IN SYNC across the whole run.' if ok else 'DESYNC DETECTED.'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
