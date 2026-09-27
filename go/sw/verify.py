"""Bit-identical correctness oracle: baseline vs optimized bm_go.

Loads both variants in one process and compares far more than the returned move:
every UCT node's win/loss record, every simulated game's board state and zobrist
hash, and the exact number of RNG draws consumed.
"""
import importlib.util
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, 'run_benchmark_baseline.py')
OPTIMIZED = os.path.join(HERE, 'run_benchmark.py')


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def capture(path, name):
    """Run versus_cpu() with instrumentation and return a full state signature."""
    mod = load(name, path)

    nodes = []
    games = []
    draws = [0]

    orig_init = mod.UCTNode.__init__
    orig_play = mod.UCTNode.play

    def init(self, *a, **kw):
        orig_init(self, *a, **kw)
        nodes.append(self)

    def play(self, board):
        orig_play(self, board)
        games.append((tuple(board.history), repr(board), board.zobrist.hash,
                      board.score(mod.BLACK), board.score(mod.WHITE)))

    # Count RNG draws without perturbing the sequence.
    real_random, real_randrange = random.random, random.randrange

    def counted_random():
        draws[0] += 1
        return real_random()

    def counted_randrange(*a, **kw):
        draws[0] += 1
        return real_randrange(*a, **kw)

    mod.UCTNode.__init__ = init
    mod.UCTNode.play = play
    random.random, random.randrange = counted_random, counted_randrange
    try:
        result = mod.versus_cpu()
    finally:
        random.random, random.randrange = real_random, real_randrange
        mod.UCTNode.__init__ = orig_init
        mod.UCTNode.play = orig_play

    # Same RNG position => identical consumption, a strict proof no path diverged.
    next_draw = real_random()

    tree = [(n.pos, n.wins, n.losses) for n in nodes]
    return {
        'result': result,
        'draws': draws[0],
        'next_draw': next_draw,
        'node_count': len(nodes),
        'tree': tree,
        'games': games,
        'moves': mod.MOVES,
        'timestamp': mod.TIMESTAMP,
    }


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    baseline = argv[0] if len(argv) > 0 else BASELINE
    optimized = argv[1] if len(argv) > 1 else OPTIMIZED
    print('baseline : %s\noptimized: %s\n' % (baseline, optimized))
    base = capture(baseline, 'go_baseline')
    opt = capture(optimized, 'go_optimized')

    ok = True
    for key in ('result', 'draws', 'next_draw', 'node_count', 'moves',
                'timestamp', 'tree', 'games'):
        if base[key] == opt[key]:
            detail = base[key] if key not in ('tree', 'games') else \
                '%d entries' % len(base[key])
            print('  OK    %-11s %s' % (key, detail))
        else:
            ok = False
            print('  FAIL  %-11s' % key)
            if key in ('tree', 'games'):
                for i, (b, o) in enumerate(zip(base[key], opt[key])):
                    if b != o:
                        print('        first diff at %d:\n          base=%r\n          opt =%r'
                              % (i, b, o))
                        break
                if len(base[key]) != len(opt[key]):
                    print('        length %d vs %d' % (len(base[key]), len(opt[key])))
            else:
                print('        base=%r opt=%r' % (base[key], opt[key]))

    if base['result'] != 5:
        ok = False
        print('  FAIL  baseline result is not the expected 5')

    print('\n%s' % ('VERIFIED: optimized output is bit-identical to baseline.'
                    if ok else 'MISMATCH: optimization is NOT correct.'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
