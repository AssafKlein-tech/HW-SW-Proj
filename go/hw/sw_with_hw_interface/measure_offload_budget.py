"""How much time does each candidate offload boundary actually own?

Run versus_cpu() once recording every return value of the function, then run
it again with the function replaced by a list index into that recording.  The
replay makes the same decisions in the same order (same RNG stream, same
result), so the difference in run time is the cost of the function body,
which is what an accelerator would remove.  Divided by the call count it gives
the time one bus round trip has to beat."""
import importlib.util
import os
import statistics
import sys
import time

BASELINE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'sw', 'run_benchmark_baseline.py')
REPS = int(os.environ.get('REPS', '15'))
MOVES = 21401          # posted MOVE writes needed to keep the shadow board in sync


def load(name):
    spec = importlib.util.spec_from_file_location(name, BASELINE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def timeit(fn):
    ts = []
    for _ in range(REPS):
        t0 = time.process_time()
        r = fn()
        ts.append(time.process_time() - t0)
        assert r == 5, r
    return ts


# --- candidate boundaries -------------------------------------------------
def record_useful():
    mod = load('rec_u')
    out = []
    real = mod.Board.useful

    def useful(self, pos):
        r = real(self, pos)
        out.append(r)
        return r
    mod.Board.useful = useful
    assert mod.versus_cpu() == 5
    return out


def replay_useful(answers):
    mod = load('rep_u')
    st = {'i': 0}

    def useful(self, pos):
        i = st['i']
        st['i'] = i + 1
        return answers[i]
    mod.Board.useful = useful
    return mod, st


def record_find():
    """Only OUTERMOST find() calls: the recursive re-entries are what the
    iterative/hardware version removes, not separate logical operations."""
    mod = load('rec_f')
    out = []
    real = mod.Square.find
    depth = [0]

    def find(self, update=False):
        depth[0] += 1
        try:
            r = real(self, update)
        finally:
            depth[0] -= 1
        if depth[0] == 0:
            out.append(r.pos)          # positions, not objects: different module
        return r
    mod.Square.find = find
    assert mod.versus_cpu() == 5
    return out


def replay_find(roots):
    mod = load('rep_f')
    st = {'i': 0}

    def find(self, update=False):
        i = st['i']
        st['i'] = i + 1
        return self.board.squares[roots[i]]
    mod.Square.find = find
    return mod, st


def price(label, record, replay, base_t):
    answers = record()
    n = len(answers)
    mod, st = replay(answers)

    ts = []
    for _ in range(REPS):
        st['i'] = 0
        t0 = time.process_time()
        r = mod.versus_cpu()
        ts.append(time.process_time() - t0)
        assert r == 5, 'replay diverged: %r' % (r,)
    assert st['i'] == n, (st['i'], n)

    b, rp = min(base_t), min(ts)
    off = b - rp
    print('%-12s %8d %12.1f %12.1f %11.1f %8.1f%% %11.3f'
          % (label, n, b * 1e3, rp * 1e3, off * 1e3, 100 * off / b, off / n * 1e6))
    return n, rp, off


def main():
    base = load('base')
    base_t = timeit(base.versus_cpu)
    b = min(base_t)

    print('baseline: %.1f ms min, %.1f ms median CPU time over %d reps\n'
          % (b * 1e3, statistics.median(base_t) * 1e3, REPS))
    print('%-12s %8s %12s %12s %11s %9s %11s'
          % ('boundary', 'calls', 'baseline', 'replayed', 'offloadable', 'share', 'us/call'))
    print('-' * 80)
    price('Square.find', record_find, replay_find, base_t)
    n, floor, off = price('Board.useful', record_useful, replay_useful, base_t)

    print('\nBoard.useful offload -- projected runtime vs round-trip cost T_txn')
    print('(%d USEFUL round trips + %d posted MOVE writes @ 0.15 us)\n' % (n, MOVES))
    print('  %-10s %-12s %-10s' % ('T_txn', 'runtime', 'speedup'))
    for t in (0.0, 0.3e-6, 0.5e-6, 1.0e-6, 1.5e-6, 2.0e-6, off / n):
        new = floor + n * t + MOVES * 0.15e-6
        tag = '   <- break-even' if abs(t - off / n) < 1e-12 else ''
        print('  %-10s %-12s %.2fx%s'
              % ('%.2f us' % (t * 1e6), '%.0f ms' % (new * 1e3), b / new, tag))
    return 0


if __name__ == '__main__':
    sys.exit(main())
