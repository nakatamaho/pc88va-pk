"""ROM-free model of the bounded tile/colour scan in src/game/pk.asm.

Run: python3 -I tests/test_render_budget.py
This checks scheduling, not V30 timing or actual level-clear rendering.
"""
import random
import unittest

PAIRS = 512
BUDGET = 16


def scan(source, shadow, cursor, budget=BUDGET):
    drawn = []
    for _ in range(PAIRS):
        if not budget:
            break
        if source[cursor] != shadow[cursor]:
            shadow[cursor] = source[cursor]
            drawn.append(cursor)
            budget -= 1
        cursor = (cursor + 1) % PAIRS
    return cursor, drawn


def blocked_scan(source, shadow, cursor, budget=BUDGET):
    """Model REPE clean-block probes and bounded pair fallback in assembly."""
    remaining, drawn = PAIRS, []
    while remaining:
        if not budget:
            return cursor, drawn, False
        count = min(16, PAIRS - cursor, remaining)
        tile_equal = all(source[i][0] == shadow[i][0]
                         for i in range(cursor, cursor + count))
        colour_equal = all(source[i][1] == shadow[i][1]
                           for i in range(cursor, cursor + count))
        if tile_equal and colour_equal:
            remaining -= count
            cursor = (cursor + count) % PAIRS
            continue
        for _ in range(count):
            if not budget:
                return cursor, drawn, False
            if source[cursor] != shadow[cursor]:
                shadow[cursor] = source[cursor]
                drawn.append(cursor)
                budget -= 1
            cursor = (cursor + 1) % PAIRS
            remaining -= 1
    return cursor, drawn, True


class RenderBudgetTests(unittest.TestCase):
    def test_repeated_early_changes_do_not_starve_tail(self):
        source = [(1, 1)] * PAIRS
        shadow = [(0, 0)] * PAIRS
        cursor = 0
        visited = set()
        for frame in range(PAIRS // BUDGET):
            for i in range(BUDGET):
                source[i] = (frame + 2, frame + 2)
            cursor, drawn = scan(source, shadow, cursor)
            self.assertLessEqual(len(drawn), BUDGET)
            visited.update(drawn)
        self.assertEqual(visited, set(range(PAIRS)))

    def test_tile_and_colour_changes_share_fair_scan(self):
        source = [(1, 0)] * 256 + [(0, 1)] * 256
        shadow = [(0, 0)] * PAIRS
        cursor = 0
        for _ in range(PAIRS // BUDGET):
            cursor, _ = scan(source, shadow, cursor)
        self.assertEqual(shadow, source)

    def test_full_render_wraps_and_draws_every_pair(self):
        for start in (0, 16, 510, 511):
            source = [(1, 1)] * PAIRS
            shadow = [(0, 0)] * PAIRS
            cursor, drawn = scan(source, shadow, start, 1024)
            self.assertEqual(cursor, start)
            self.assertEqual(len(drawn), PAIRS)
            self.assertEqual(shadow, source)

    def test_block_probe_preserves_pair_order_and_budget(self):
        rng = random.Random(42)
        for trial in range(2000):
            source = [(0, 0)] * PAIRS
            shadow = source[:]
            for _ in range(rng.randrange(513)):
                source[rng.randrange(PAIRS)] = (rng.randrange(3), rng.randrange(3))
            cursor = rng.randrange(PAIRS)
            budget = rng.choice((1, 16, 1024))
            expected = shadow[:]
            want = scan(source, expected, cursor, budget)
            got_cursor, got_drawn, complete = blocked_scan(source, shadow, cursor, budget)
            self.assertEqual((got_cursor, got_drawn), want, trial)
            self.assertEqual(shadow, expected, trial)
            if complete:
                self.assertEqual(shadow, source, trial)

    def test_incomplete_page_is_not_presented(self):
        source = [(1, 1)] * PAIRS
        shadow = [(0, 0)] * PAIRS
        cursor, held, quiet = 0, False, 0
        for _ in range(40):
            # Previous draw is presentable only outside the transaction.
            if not held and quiet:
                self.assertEqual(shadow, source)
                return
            cursor, drawn, complete = blocked_scan(source, shadow, cursor)
            if not complete:
                held, quiet = True, 0
            elif held:
                quiet += 1
                if quiet == 2:
                    held = False
        self.fail("scene never completed")

    def test_clean_scan_is_bounded(self):
        source = [(0, 0)] * PAIRS
        cursor, drawn = scan(source, source[:], 37)
        self.assertEqual((cursor, drawn), (37, []))


if __name__ == "__main__":
    unittest.main()
