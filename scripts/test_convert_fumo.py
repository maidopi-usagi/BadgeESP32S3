import importlib.util
from pathlib import Path
import struct
import sys
import unittest

source_path = Path(sys.argv[1])
module_path = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location('convert_fumo', module_path)
converter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(converter)


class ConversionTests(unittest.TestCase):
    def test_node_quaternion_makes_the_model_upright(self):
        doc, _ = converter.load_glb(source_path.read_bytes())
        q = doc['nodes'][0]['rotation']
        result = converter.rotate(q, (0, 0, -1))
        for actual, expected in zip(result, (0, 1, 0)):
            self.assertAlmostEqual(actual, expected, places=5)

    def test_smaller_texture_preserves_mesh_and_saves_75_percent(self):
        source = source_path.read_bytes()
        small = converter.convert(source, 128)
        full = converter.convert(source, 256)
        offset = struct.unpack_from('<I', small, 24)[0]
        self.assertEqual(small[32:offset], full[32:offset])
        self.assertEqual(struct.unpack_from('<I', small, 12)[0], 271)
        self.assertEqual(len(small) - offset, 32768)
        self.assertEqual(len(full) - offset, 4 * 32768)

    def test_damaged_glb_and_png_are_rejected(self):
        source = source_path.read_bytes()
        with self.assertRaises(ValueError):
            converter.load_glb(source[:-1])
        with self.assertRaises(ValueError):
            converter.load_glb(b'BAD!' + source[4:])
        doc, binary = converter.load_glb(source)
        png, _ = converter.view_bytes(doc, binary, doc['images'][0]['bufferView'])
        damaged = bytearray(png)
        damaged[29] ^= 1  # IHDR CRC, without changing the decoded dimensions.
        with self.assertRaisesRegex(ValueError, 'CRC'):
            converter.decode_png(damaged)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]])
