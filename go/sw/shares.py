"""Self and inclusive time per function from py-spy's collapsed stacks.

usage: python3 shares.py <collapsed.txt> [baseline_ms]
Inclusive share is the width of the function's box in the flame graph, i.e.
everything nested under it.  That is what an offload removes, so it is the
number to divide by the call count when pricing a hardware boundary.
"""
import sys
from collections import Counter

tot = 0
inc = Counter()
exc = Counter()
find_total = find_in_useful = 0
for line in open(sys.argv[1]):
    stack, _, n = line.rstrip('\n').rpartition(' ')
    if not n.isdigit():
        continue
    n = int(n)
    tot += n
    frames = [f.strip().split(' (')[0] for f in stack.split(';') if f.strip()]
    if not frames:
        continue
    for name in set(frames):
        inc[name] += n
    exc[frames[-1]] += n
    if 'find' in frames:
        find_total += n
        if 'useful' in frames[:frames.index('find')]:
            find_in_useful += n

ms = float(sys.argv[2]) if len(sys.argv) > 2 else None
print('samples: %d' % tot)
print('%-16s %8s %8s' % ('function', 'incl', 'self') + ('%10s %10s' % ('incl ms', 'self ms') if ms else ''))
for f in ('random_choice', 'useful', 'move', 'find', 'remove', 'useful_fast'):
    row = '%-16s %7.1f%% %7.1f%%' % (f, 100 * inc[f] / tot, 100 * exc[f] / tot)
    if ms:
        row += ' %10.1f %10.1f' % (ms * inc[f] / tot, ms * exc[f] / tot)
    print(row)
print('find time nested inside useful: %.1f%%' % (100 * find_in_useful / find_total))
