"""Optimized version of pyperformance's "mdp" benchmark.

Baseline profiling (see profile_callers_baseline.txt, perf_baseline_flat_report.txt)
showed `fractions.Fraction` accounting for ~24% of total runtime (fractions.py:_add,
forward, __new__, math.gcd combined). It's used only to build intermediate
probability distributions in getCritDist/_applyActionSide1/_getSuccessorsB/
_getSuccessorsC -- every one of those already converts its result to plain `float`
before returning (_getSuccessorsB/_getSuccessorsC end with `float(p)`, and
evaluate()'s dmin/dmax accumulators are `defaultdict(float)` from the start). So
Fraction's exactness was already being discarded a few lines later; using float
from the start just moves that same rounding earlier. Two of the three probability
ratios involved (basespeed/pdiv, with pdiv in {64, 512}) have power-of-2
denominators and are represented *exactly* in binary float regardless; the
remaining ratios (64/130, 66/130) round the same way float() would have rounded
them anyway. Net error is ~1e-15, far under the benchmark's 1e-6 correctness
tolerance.

Second optimization, in Battle.evaluate(): the value-iteration loop originally
keyed dmin/dmax/frozen/successors by the raw statep tuple (a nested-namedtuple
hash on every access), even though only ~4823 distinct states are ever reachable.
Since topoSort() already visits every reachable state exactly once, its output
order is used to assign each state an integer id, and dmin/dmax/frozen/the
successor lists are rebuilt as plain lists indexed by that id -- turning every
hash+lookup in the hot loop into direct array indexing. getSuccessors() itself
(and its statep-keyed self.successors cache used during the one-time topoSort
discovery pass) is unchanged.
"""
import collections
from collections import defaultdict

import pyperf


def topoSort(roots, getParents):
    """Return a topological sorting of nodes in a graph.

    roots - list of root nodes to search from
    getParents - function which returns the parents of a given node
    """

    results = []
    visited = set()

    # Use iterative version to avoid stack limits for large datasets
    stack = [(node, 0) for node in roots]
    while stack:
        current, state = stack.pop()
        if state == 0:
            # before recursing
            if current not in visited:
                visited.add(current)
                stack.append((current, 1))
                stack.extend((parent, 0) for parent in getParents(current))
        else:
            # after recursing
            assert(current in visited)
            results.append(current)
    return results


def getDamages(L, A, D, B, stab, te):
    x = (2 * L) // 5
    x = ((x + 2) * A * B) // (D * 50) + 2
    if stab:
        x += x // 2
    x = int(x * te)
    return [(x * z) // 255 for z in range(217, 256)]


def getCritDist(L, p, A1, A2, D1, D2, B, stab, te):
    p = min(p, 1.0)
    norm = getDamages(L, A1, D1, B, stab, te)
    crit = getDamages(L * 2, A2, D2, B, stab, te)

    dist = defaultdict(float)
    for mult, vals in zip([1 - p, p], [norm, crit]):
        mult /= len(vals)
        for x in vals:
            dist[x] += mult
    return dist


def plus12(x):
    return x + x // 8


stats_t = collections.namedtuple('stats_t', ['atk', 'df', 'speed', 'spec'])
NOMODS = stats_t(0, 0, 0, 0)


fixeddata_t = collections.namedtuple(
    'fixeddata_t', ['maxhp', 'stats', 'lvl', 'badges', 'basespeed'])
halfstate_t = collections.namedtuple(
    'halfstate_t', ['fixed', 'hp', 'status', 'statmods', 'stats'])


def applyHPChange(hstate, change):
    hp = min(hstate.fixed.maxhp, max(0, hstate.hp + change))
    return hstate._replace(hp=hp)


def applyBadgeBoosts(badges, stats):
    return stats_t(*[(plus12(x) if b else x) for x, b in zip(stats, badges)])


attack_stats_t = collections.namedtuple(
    'attack_stats_t', ['power', 'isspec', 'stab', 'te', 'crit'])
attack_data = {
    'Ember': attack_stats_t(40, True, True, 0.5, False),
    'Dig': attack_stats_t(100, False, False, 1, False),
    'Slash': attack_stats_t(70, False, False, 1, True),
    'Water Gun': attack_stats_t(40, True, True, 2, False),
    'Bubblebeam': attack_stats_t(65, True, True, 2, False),
}


def _applyActionSide1(state, act):
    me, them, extra = state

    if act == 'Super Potion':
        me = applyHPChange(me, 50)
        return {(me, them, extra): 1.0}

    mdata = attack_data[act]
    aind = 3 if mdata.isspec else 0
    dind = 3 if mdata.isspec else 1
    pdiv = 64 if mdata.crit else 512
    dmg_dist = getCritDist(me.fixed.lvl, me.fixed.basespeed / pdiv,
                           me.stats[aind], me.fixed.stats[aind], them.stats[
                               dind], them.fixed.stats[dind],
                           mdata.power, mdata.stab, mdata.te)

    dist = defaultdict(float)
    for dmg, p in dmg_dist.items():
        them2 = applyHPChange(them, -dmg)
        dist[me, them2, extra] += p
    return dist


def _applyAction(state, side, act):
    if side == 0:
        return _applyActionSide1(state, act)
    else:
        me, them, extra = state
        dist = _applyActionSide1((them, me, extra), act)
        return {(k[1], k[0], k[2]): v for k, v in dist.items()}


class Battle(object):

    def __init__(self):
        self.successors = {}

        self.win = 4, True
        self.loss = 4, False

    def _getSuccessorsA(self, statep):
        st, state = statep
        for action in ['Dig', 'Super Potion']:
            yield (1, state, action)

    def _applyActionPair(self, state, side1, act1, side2, act2, dist, pmult):
        for newstate, p in _applyAction(state, side1, act1).items():
            if newstate[0].hp == 0:
                newstatep = self.loss
            elif newstate[1].hp == 0:
                newstatep = self.win
            else:
                newstatep = 2, newstate, side2, act2
            dist[newstatep] += p * pmult

    def _getSuccessorsB(self, statep):
        st, state, action = statep
        dist = defaultdict(float)
        for eact, p in [('Water Gun', 64 / 130),
                        ('Bubblebeam', 66 / 130)]:
            priority1 = state[0].stats.speed + \
                10000 * (action == 'Super Potion')
            priority2 = state[1].stats.speed + 10000 * (action == 'X Defend')

            if priority1 > priority2:
                self._applyActionPair(state, 0, action, 1, eact, dist, p)
            elif priority1 < priority2:
                self._applyActionPair(state, 1, eact, 0, action, dist, p)
            else:
                self._applyActionPair(state, 0, action, 1, eact, dist, p / 2)
                self._applyActionPair(state, 1, eact, 0, action, dist, p / 2)

        return {k: p for k, p in dist.items() if p > 0}

    def _getSuccessorsC(self, statep):
        st, state, side, action = statep
        dist = defaultdict(float)
        for newstate, p in _applyAction(state, side, action).items():
            if newstate[0].hp == 0:
                newstatep = self.loss
            elif newstate[1].hp == 0:
                newstatep = self.win
            else:
                newstatep = 0, newstate
            dist[newstatep] += p
        return {k: p for k, p in dist.items() if p > 0}

    def getSuccessors(self, statep):
        try:
            return self.successors[statep]
        except KeyError:
            st = statep[0]
        if st == 0:
            result = list(self._getSuccessorsA(statep))
        else:
            if st == 1:
                dist = self._getSuccessorsB(statep)
            elif st == 2:
                dist = self._getSuccessorsC(statep)
            result = sorted(dist.items(), key=lambda t: (-t[1], t[0]))
        self.successors[statep] = result
        return result

    def getSuccessorsList(self, statep):
        if statep[0] == 4:
            return []
        temp = self.getSuccessors(statep)
        if statep[0] != 0:
            temp = list(zip(*temp))[0] if temp else []
        return temp

    def evaluate(self, tolerance=0.15):
        badges = 1, 0, 0, 0

        starfixed = fixeddata_t(59, stats_t(40, 44, 56, 50), 11, NOMODS, 115)
        starhalf = halfstate_t(starfixed, 59, 0, NOMODS,
                               stats_t(40, 44, 56, 50))
        charfixed = fixeddata_t(63, stats_t(39, 34, 46, 38), 26, badges, 65)
        charhalf = halfstate_t(charfixed, 63, 0, NOMODS, applyBadgeBoosts(
            badges, stats_t(39, 34, 46, 38)))
        initial_state = charhalf, starhalf, 0
        initial_statep = 0, initial_state

        stateps = topoSort([initial_statep], self.getSuccessorsList)

        # Only ~4823 states are ever reachable (confirmed by profiling), and the
        # topoSort call above already discovered and numbered them all in one DFS
        # pass (self.successors got populated as a side effect). Assign each state
        # an integer id equal to its position in that order, then replace every
        # statep-keyed dict/set used in the hot loop below with a plain list
        # indexed by id -- trading tuple hashing (PyObject_Hash/tuplehash were the
        # top two entries in perf_baseline_flat_report.txt, ~18% of samples
        # combined) for direct array indexing. getSuccessors/getSuccessorsList/
        # topoSort themselves are untouched; this is a one-time O(n) translation.
        id_of = {sp: i for i, sp in enumerate(stateps)}
        n = len(stateps)

        succ_ids = []
        is_choice = []
        for sp in stateps:
            if sp[0] == 4:
                # terminal win/loss state: always frozen, never read below
                succ_ids.append(())
                is_choice.append(False)
                continue
            raw = self.successors[sp]
            if sp[0] == 0:
                is_choice.append(True)
                succ_ids.append([id_of[sp2] for sp2 in raw])
            else:
                is_choice.append(False)
                succ_ids.append([(id_of[sp2], p) for sp2, p in raw])

        dmin = [0.0] * n
        dmax = [1.0] * n
        frozen = [False] * n

        win_id = id_of[self.win]
        loss_id = id_of[self.loss]
        dmax[loss_id] = 0.0
        dmin[win_id] = 1.0
        frozen[win_id] = True
        frozen[loss_id] = True

        initial_id = id_of[initial_statep]

        itercount = 0
        while dmax[initial_id] - dmin[initial_id] > tolerance:
            itercount += 1

            for i in range(n):
                if frozen[i]:
                    continue

                if is_choice[i]:
                    # choice node
                    dmin[i] = max(dmin[j] for j in succ_ids[i])
                    dmax[i] = max(dmax[j] for j in succ_ids[i])
                else:
                    dmin[i] = sum(dmin[j] * p for j, p in succ_ids[i])
                    dmax[i] = sum(dmax[j] * p for j, p in succ_ids[i])

                if dmin[i] >= dmax[i]:
                    dmax[i] = dmin[i] = (dmin[i] + dmax[i]) / 2
                    frozen[i] = True
        return (dmax[initial_id] + dmin[initial_id]) / 2


def bench_mdp(loops):
    expected = 0.89873589887
    max_diff = 1e-6
    range_it = range(loops)

    t0 = pyperf.perf_counter()
    for _ in range_it:
        result = Battle().evaluate(0.192)
    dt = pyperf.perf_counter() - t0

    if abs(result - expected) > max_diff:
        raise Exception("invalid result: got %s, expected %s "
                        "(diff: %s, max diff: %s)"
                        % (result, expected, result - expected, max_diff))
    return dt


if __name__ == "__main__":
    runner = pyperf.Runner()
    runner.metadata['description'] = "MDP benchmark (optimized: float instead of Fraction, id-indexed lists instead of dicts in evaluate())"
    runner.bench_time_func('mdp', bench_mdp)
