"""Markdown text that occupies every private-use escape window in the BMP.

journal-cli hides escaped punctuation in a private-use window the line does
not already use. One character in each 26-codepoint window of U+E000..U+F8FF
leaves no free window there, which used to make it reuse an occupied one and
rewrite those characters as punctuation.

  make-pua.py FILE     write the Markdown to FILE
  make-pua.py --expect print the plain text it must render to
"""
import sys

WIDTH = 26  # len(ESCAPABLE) in Markdown.swift: 18 punctuation + 8 controls
chars = "".join(chr(0xE000 + i * WIDTH) for i in range((0xF8FF - 0xE000) // WIDTH + 1))

if sys.argv[1] == "--expect":
    print(chars + " *kept*")
else:
    with open(sys.argv[1], "w", encoding="utf-8") as fh:
        fh.write(chars + " \\*kept\\*")
