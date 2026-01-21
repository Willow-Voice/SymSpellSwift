#!/usr/bin/env python3
"""
Generate keyboard layout binary files for spatial error weighting in SymSpell.

This script pre-computes key distances for different keyboard layouts and saves
them as compact binary files that can be loaded by the Swift LowMemorySymSpell
implementation.

Usage:
    python scripts/generate_keyboard_layout.py --layout qwerty --output ./keyboard_layouts

Binary format:
    - Header: "KYBD" (4 bytes magic) + version (1 byte)
    - Distance matrix: 26x26 bytes for lowercase letters a-z
      - Value at [i][j] = keyboard distance from letter i to letter j
      - 0 = same key
      - 1 = directly adjacent (ring 1)
      - 2 = distance 2 away (ring 2)
      - 255 = far away / not related

Total file size: 681 bytes per layout.
"""

import argparse
import os
import struct
from typing import Dict, List, Set, Tuple

# Magic header for keyboard layout files
MAGIC = b"KYBD"
VERSION = 1

# QWERTY keyboard layout - each row is a list of keys
QWERTY_ROWS = [
    list("qwertyuiop"),
    list("asdfghjkl"),
    list("zxcvbnm"),
]

# AZERTY keyboard layout (French)
AZERTY_ROWS = [
    list("azertyuiop"),
    list("qsdfghjklm"),
    list("wxcvbn"),
]

# QWERTZ keyboard layout (German)
QWERTZ_ROWS = [
    list("qwertzuiop"),
    list("asdfghjkl"),
    list("yxcvbnm"),
]

# Dvorak keyboard layout
DVORAK_ROWS = [
    list("pyfgcrl"),
    list("aoeuidhtns"),
    list("qjkxbmwvz"),
]

# Colemak keyboard layout
COLEMAK_ROWS = [
    list("qwfpgjluy"),
    list("arstdhneio"),
    list("zxcvbkm"),
]

# Layout name to rows mapping
LAYOUTS = {
    "qwerty": QWERTY_ROWS,
    "azerty": AZERTY_ROWS,
    "qwertz": QWERTZ_ROWS,
    "dvorak": DVORAK_ROWS,
    "colemak": COLEMAK_ROWS,
}


def get_key_positions(rows: List[List[str]]) -> Dict[str, Tuple[int, int]]:
    """
    Get (row, col) position for each key.

    Handles staggered keyboard layout - rows are offset by ~0.5 keys.
    We use half-key precision internally: col is doubled for accurate distance.
    """
    positions = {}

    # Row offsets to simulate keyboard stagger (in half-key units)
    # Top row: no offset
    # Middle row: offset by 0.5 keys (1 half-key)
    # Bottom row: offset by 1 key (2 half-keys)
    row_offsets = [0, 1, 3]

    for row_idx, row in enumerate(rows):
        offset = row_offsets[row_idx] if row_idx < len(row_offsets) else row_idx * 2
        for col_idx, key in enumerate(row):
            # Use half-key precision: multiply col by 2
            positions[key] = (row_idx * 2, col_idx * 2 + offset)

    return positions


def compute_distance_matrix(rows: List[List[str]], max_distance: int = 2) -> List[List[int]]:
    """
    Compute keyboard distance matrix for all letter pairs.

    Returns 26x26 matrix where matrix[i][j] is the keyboard distance
    from letter chr(ord('a') + i) to letter chr(ord('a') + j).

    Distance is computed using Chebyshev distance (max of row/col diff)
    with keyboard stagger accounted for.
    """
    positions = get_key_positions(rows)

    # Initialize 26x26 matrix with 255 (far away)
    matrix = [[255 for _ in range(26)] for _ in range(26)]

    for i in range(26):
        char_i = chr(ord('a') + i)

        for j in range(26):
            char_j = chr(ord('a') + j)

            if i == j:
                # Same key
                matrix[i][j] = 0
            elif char_i in positions and char_j in positions:
                pos_i = positions[char_i]
                pos_j = positions[char_j]

                # Compute distance using Chebyshev distance
                # (accounts for diagonal adjacency)
                row_diff = abs(pos_i[0] - pos_j[0])
                col_diff = abs(pos_i[1] - pos_j[1])

                # Convert from half-key units to key units
                # Adjacent keys differ by ~2 half-key units
                chebyshev = max(row_diff, col_diff)

                if chebyshev <= 2:
                    # Distance 1: immediately adjacent
                    matrix[i][j] = 1
                elif chebyshev <= 4:
                    # Distance 2: one key away
                    matrix[i][j] = 2
                else:
                    # Far away
                    matrix[i][j] = 255
            # else: not on keyboard, stays 255

    return matrix


def get_adjacent_keys(rows: List[List[str]]) -> Dict[str, Set[str]]:
    """Get set of adjacent keys for each key (for debugging/verification)."""
    matrix = compute_distance_matrix(rows)
    adjacent = {}

    for i in range(26):
        char_i = chr(ord('a') + i)
        neighbors = set()
        for j in range(26):
            if matrix[i][j] == 1:
                neighbors.add(chr(ord('a') + j))
        adjacent[char_i] = neighbors

    return adjacent


def write_layout_file(output_path: str, rows: List[List[str]]) -> None:
    """Write keyboard layout to binary file."""
    matrix = compute_distance_matrix(rows)

    with open(output_path, 'wb') as f:
        # Write header
        f.write(MAGIC)
        f.write(struct.pack('B', VERSION))

        # Write 26x26 distance matrix
        for row in matrix:
            f.write(bytes(row))

    print(f"  Written {os.path.getsize(output_path)} bytes to {output_path}")


def print_adjacency_info(layout_name: str, rows: List[List[str]]) -> None:
    """Print adjacency information for debugging."""
    adjacent = get_adjacent_keys(rows)

    print(f"\n{layout_name.upper()} adjacency (distance 1):")
    for key in sorted(adjacent.keys()):
        neighbors = sorted(adjacent[key])
        print(f"  {key}: {', '.join(neighbors)}")


def main():
    parser = argparse.ArgumentParser(
        description="Generate keyboard layout binary files for spatial error weighting"
    )
    parser.add_argument(
        "--layout", "-l",
        choices=list(LAYOUTS.keys()) + ["all"],
        default="all",
        help="Keyboard layout to generate (default: all)"
    )
    parser.add_argument(
        "--output", "-o",
        default="./keyboard_layouts",
        help="Output directory for layout files"
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Print adjacency information"
    )
    args = parser.parse_args()

    # Create output directory
    os.makedirs(args.output, exist_ok=True)

    layouts_to_generate = list(LAYOUTS.keys()) if args.layout == "all" else [args.layout]

    print(f"Generating keyboard layout files...")
    print(f"  Output directory: {args.output}")
    print()

    for layout_name in layouts_to_generate:
        rows = LAYOUTS[layout_name]
        output_path = os.path.join(args.output, f"keyboard_{layout_name}.bin")

        print(f"Generating {layout_name}...")
        write_layout_file(output_path, rows)

        if args.verbose:
            print_adjacency_info(layout_name, rows)

    print(f"\nDone! Generated {len(layouts_to_generate)} layout file(s).")
    print(f"\nUsage in Swift:")
    print(f"  let symSpell = LowMemorySymSpell(")
    print(f"      maxEditDistance: 2,")
    print(f"      prefixLength: 7,")
    print(f"      keyboardLayout: .qwerty")
    print(f"  )")


if __name__ == "__main__":
    main()
