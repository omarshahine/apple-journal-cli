"""Unit tests for the Python reference's internals that the CLI suite can't
reach. Run: python3 -m unittest discover -s tests -p 'test_reference.py'"""
import importlib.util, os, subprocess, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ref", os.path.join(HERE, "..", "reference", "journal-cli.py"))
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)


def rtf(n):
    return ("{\\rtf1\\ansi entry %d}" % n).encode()


class RTFBatchTests(unittest.TestCase):
    def test_more_than_one_batch_keeps_every_position(self):
        blobs = [rtf(i) if i % 7 else None for i in range(450)]  # gaps too
        out = ref.rtf_batch(blobs)
        self.assertEqual(len(out), 450)
        for i, t in enumerate(out):
            self.assertEqual(t, "" if i % 7 == 0 else "entry %d" % i, i)

    def test_a_failed_earlier_batch_is_reported(self):
        real = subprocess.run
        calls = []

        def run(cmd, *a, **kw):
            r = real(cmd, *a, **kw)
            calls.append(cmd)
            if len(calls) == 1:
                return subprocess.CompletedProcess(cmd, 1, b"", b"boom")
            return r

        with mock.patch.object(ref.subprocess, "run", run):
            with self.assertRaises(SystemExit):
                ref.rtf_batch([rtf(i) for i in range(250)])
        self.assertGreaterEqual(len(calls), 2)   # the later batch still ran


if __name__ == "__main__":
    unittest.main()
