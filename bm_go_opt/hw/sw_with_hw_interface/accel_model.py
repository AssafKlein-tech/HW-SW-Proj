"""Cycle-faithful behavioural model of the `go_useful_accel` hardware block.

This is the *golden model*: it implements exactly the algorithm the SystemVerilog
RTL implements (same arrays, same widths, same traversal order), and it is what
`bm_go_hw/run_benchmark.py` calls in place of `Board.useful`.  Running the
benchmark against this model proves the hardware/software *partition* is
bit-exact; dumping its op stream (see hw/model/gen_trace.py) then proves the RTL
against the real workload rather than against hand-written vectors.

Hardware state modelled (81-point 9x9 board, ~18 kbit total):
    color[81] x 2b   ref[81] x 7b   ledges[81] x 9b   used[81] x 1b
    temp_ledges[81] x 9b   root_seen[81] x 1b   removed[81] x 1b
    ZKEY 243 x 63b   hash 63b
"""

SIZE = 9
NPTS = SIZE * SIZE
EMPTY, WHITE, BLACK = 0, 1, 2

# NEIGH_ROM: 81 x (up to 4 x 7b).  Fixed 9x9 geometry, resolved at elaboration.
NEIGH = []
for _pos in range(NPTS):
    _x, _y = _pos % SIZE, _pos // SIZE
    _n = []
    for _dx, _dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        _nx, _ny = _x + _dx, _y + _dy
        if 0 <= _nx < SIZE and 0 <= _ny < SIZE:
            _n.append(_ny * SIZE + _nx)
    NEIGH.append(tuple(_n))

# opcodes (CMD[31:28])
OP_NOP, OP_RESET, OP_MOVE, OP_USEFUL, OP_LOAD_KEY = 0, 1, 2, 3, 4


class GoUsefulAccel:
    """Shadow copy of the board's group/liberty structure."""

    def __init__(self, trace=None):
        self.zkey = [0] * (NPTS * 3)          # ZKEY RAM, index = sq*3 + color
        self.color = [EMPTY] * NPTS
        self.ref = list(range(NPTS))
        self.ledges = [0] * NPTS
        self.used = [False] * NPTS
        self.temp = [0] * NPTS
        self.hash = 0
        self.trace = trace                    # optional op recorder

    # ---- ops -----------------------------------------------------------
    def load_keys(self, squares):
        """OP_LOAD_KEY x 243.  Once per Board() construction."""
        for sq in squares:
            for c in (EMPTY, WHITE, BLACK):
                idx = sq.pos * 3 + c
                self.zkey[idx] = sq.zobrist_strings[c]
                if self.trace:
                    self.trace.load_key(idx, sq.zobrist_strings[c])

    def reset(self):
        """OP_RESET.  Parallel clear + 81-cycle recompute of the empty-board hash."""
        self.color = [EMPTY] * NPTS
        self.ref = list(range(NPTS))
        self.ledges = [0] * NPTS
        self.used = [False] * NPTS
        h = 0
        for sq in range(NPTS):
            h ^= self.zkey[sq * 3 + EMPTY]
        self.hash = h
        if self.trace:
            self.trace.reset()

    def find(self, p, compress=False):
        """Walk to the root, 1 cycle per hop.

        `compress` mirrors CPython's find(update=True): a second walk repoints
        every node on the path at the root.  It is used only on the MOVE path
        (exactly as in software).  It never changes *which* node is the root, so
        USEFUL results do not depend on it -- but leaving it out lets chains
        reach depth 36 on this workload instead of 8, so the RTL keeps it."""
        ref = self.ref
        root = p
        while ref[root] != root:
            root = ref[root]
        if compress:
            while ref[p] != root:
                p, ref[p] = ref[p], root
        return root

    def useful(self, pos, color):
        """OP_USEFUL -> (fast_path, useful_cond, hash).  Commits nothing."""
        colr, used = self.color, self.used
        # --- fast path: untouched point with an empty neighbour
        if not used[pos]:
            for n in NEIGH[pos]:
                if colr[n] == EMPTY:
                    if self.trace:
                        self.trace.useful(pos, color, 1, 1, 0)
                    return (1, 1, 0)
        zkey = self.zkey
        h = self.hash ^ zkey[pos * 3 + colr[pos]] ^ zkey[pos * 3 + color]
        root_seen = bytearray(NPTS)
        removed = bytearray(NPTS)
        temp = self.temp
        empties = opps = weak_opps = neighs = weak_neighs = 0
        for n in NEIGH[pos]:
            nc = colr[n]
            if nc == EMPTY:
                empties += 1
                continue
            r = self.find(n)
            if not root_seen[r]:
                root_seen[r] = 1
                temp[r] = self.ledges[r]
                if nc == color:
                    neighs += 1
                else:
                    opps += 1
            temp[r] -= 1
            if temp[r] == 0:
                if nc == color:
                    weak_neighs += 1
                else:
                    weak_opps += 1
                    h = self._cascade(r, removed, h)
        strong_neighs = neighs - weak_neighs
        strong_opps = opps - weak_opps
        cond = 1 if (empties or weak_opps or
                     (strong_neighs and (strong_opps or weak_neighs))) else 0
        if self.trace:
            self.trace.useful(pos, color, 0, cond, h)
        return (0, cond, h)

    def move(self, pos, color):
        """OP_MOVE.  Posted write - the CPU never waits for it."""
        colr, ref, ledges, zkey = self.color, self.ref, self.ledges, self.zkey
        self.hash ^= zkey[pos * 3 + colr[pos]] ^ zkey[pos * 3 + color]
        colr[pos] = color
        ref[pos] = pos
        ledges[pos] = 0
        self.used[pos] = True
        removed = bytearray(NPTS)
        for n in NEIGH[pos]:
            nc = colr[n]
            if nc == EMPTY:
                ledges[pos] += 1
            else:
                r = self.find(n, compress=True)
                if nc == color:
                    if ref[r] != pos:
                        ledges[pos] += ledges[r]
                        ref[r] = pos
                    ledges[pos] -= 1
                else:
                    ledges[r] -= 1
                    if ledges[r] == 0:
                        self._remove_commit(n, r, removed)
        if self.trace:
            self.trace.move(pos, color, self.hash)

    # ---- internal traversals -------------------------------------------
    def _cascade(self, root, removed, h):
        """Speculative capture (Square.remove with update=False): flood-fill the
        group, XOR each stone's key pair into the candidate hash.  XOR is
        commutative, so the RTL's DFS order need not match CPython's recursion."""
        colr, zkey = self.color, self.zkey
        stack = [root]
        while stack:
            s = stack.pop()
            if removed[s]:
                continue
            removed[s] = 1
            h ^= zkey[s * 3 + colr[s]] ^ zkey[s * 3 + EMPTY]
            for n in NEIGH[s]:
                if colr[n] != EMPTY and not removed[n] and self.find(n) == root:
                    stack.append(n)
        return h

    def _remove_commit(self, sq, root, removed):
        """Committed capture (Square.remove with update=True)."""
        colr, zkey, ledges = self.color, self.zkey, self.ledges
        self.hash ^= zkey[sq * 3 + colr[sq]] ^ zkey[sq * 3 + EMPTY]
        removed[sq] = 1
        colr[sq] = EMPTY
        for n in NEIGH[sq]:
            if colr[n] != EMPTY and not removed[n]:
                r2 = self.find(n, compress=True)
                if r2 == root:
                    self._remove_commit(n, root, removed)
                else:
                    ledges[r2] += 1
