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

class BuildTests(unittest.TestCase):
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
