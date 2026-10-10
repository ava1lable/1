"""Static/packaging fixtures only; never claim to compile or operate an iPhone."""
from pathlib import Path
import importlib.util
import plistlib
import struct
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('photo_build', ROOT / 'build.py')
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)

def macho(platform=2):
    return struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 2, 1, 24, 0, 0) + struct.pack('<6I', 0x32, 24, platform, 16 << 16, 18 << 16, 0)

def universal(second_platform=2):
    first = macho(); second = bytearray(macho(second_platform)); struct.pack_into('<I', second, 8, 2)
    table = struct.pack('>7I', 0xcafebabe, 2, 0x0100000c, 0, 48, len(first), 0)
    table += struct.pack('>5I', 0x0100000c, 2, 48 + len(first), len(second), 0)
    return table + first + second

class BuildTests(unittest.TestCase):
    def test_universal_arm64_and_arm64e_preserved(self):
        self.assertEqual([0, 2], [a['subtype'] for a in b.macho_architectures(universal())])

    def test_universal_simulator_slice_rejected(self):
        with self.assertRaises(RuntimeError): b.macho_architectures(universal(7))

    def test_universal_out_of_bounds_slice_rejected(self):
        data = bytearray(universal()); struct.pack_into('>I', data, 36, len(data) + 100)
        with self.assertRaises(RuntimeError): b.macho_architectures(bytes(data))

    def test_legacy_ios_device_load_command(self):
        data = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 2, 1, 16, 0, 0) + struct.pack('<4I', 0x25, 16, 16 << 16, 18 << 16)
        self.assertEqual('iOS-device', b.macho_architectures(data)[0]['platform'])

    def test_simulator_binary_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            binary=Path(temp)/'test'; binary.write_bytes(macho(7))
            with self.assertRaises(RuntimeError): b.verify_macho(binary)

    def test_device_macho_fixture_parses(self):
        with tempfile.TemporaryDirectory() as temp:
            binary=Path(temp)/'test'; binary.write_bytes(macho()); b.verify_macho(binary)

    def test_packaging_preserves_nested_test_and_removes_signing_debug_files(self):
        with tempfile.TemporaryDirectory() as temp:
            app=Path(temp)/'Runner.app'; test=app/'PlugIns/Test.xctest'; test.mkdir(parents=True)
            (app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Runner','CFBundleSupportedPlatforms':['iPhoneOS']}))
            (app/'Runner').write_bytes(macho()); (app/'Runner').chmod(0o755)
            (test/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Test'})); (test/'Test').write_bytes(macho())
            library=app/'Frameworks/WebDriverAgentLib.framework'; library.mkdir(parents=True)
            (library/'WebDriverAgentLib').write_bytes(macho()+b'MirrorGoodGood-WDA-Photos')
            debug=test/'Test.dSYM/Contents/Resources/DWARF'; debug.mkdir(parents=True); (debug/'Test').write_bytes(b'not an app')
            (app/'embedded.mobileprovision').write_bytes(b'fixture signing material')
            result=b.package_app(app, Path(temp)/'out')
            self.assertFalse(result['signed']); self.assertFalse(result['physical_phone_tested'])
            with zipfile.ZipFile(Path(temp)/'out'/result['ipa']) as z:
                self.assertFalse(any('.dSYM' in n or 'mobileprovision' in n for n in z.namelist()))
                self.assertIn('Payload/Runner.app/PlugIns/Test.xctest/Test',z.namelist())
                info=plistlib.loads(z.read('Payload/Runner.app/Info.plist'))
                self.assertIn('NSPhotoLibraryAddUsageDescription',info)
                self.assertNotIn('NSPhotoLibraryUsageDescription',info)

    def test_plain_text_cannot_be_mislabeled_as_a_compiled_ipa(self):
        with tempfile.TemporaryDirectory() as temp:
            binary=Path(temp)/'test'; binary.write_text('source only')
            with self.assertRaises(RuntimeError): b.verify_macho(binary)

if __name__=='__main__': unittest.main(verbosity=2)
