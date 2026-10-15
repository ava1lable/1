from pathlib import Path
import importlib.util
import unittest
import struct

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('touch_build',ROOT/'build.py')
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

class PackageBoundaries(unittest.TestCase):
    def test_bundle_prefix(self):
        host,test=module.bundle_identifiers('com.example.touch.runner')
        self.assertTrue(test.startswith(host+'.'))
    def test_symbols_and_old_signatures_excluded(self):
        for p in ('PlugIns/Runner.xctest.dSYM/Contents/Resources/DWARF/Runner',
                  '_CodeSignature/CodeResources','embedded.mobileprovision'):
            self.assertFalse(module.allowed_payload(Path(p)))
        self.assertTrue(module.allowed_payload(Path('PlugIns/Runner.xctest/Runner')))
    def test_only_three_routes(self):
        source=(ROOT/'patches/JHHControlCommands.m').read_text(encoding='utf-8')
        self.assertEqual(source.count('[FBRoute '),3)
        for forbidden in ('typeText:', 'setValue:', 'PHPhotoLibrary', 'screenshot'):
            self.assertNotIn(forbidden,source)
    def test_replay_consumed_before_synthesis(self):
        source=(ROOT/'patches/JHHControlCommands.m').read_text(encoding='utf-8')
        self.assertLess(source.index('JHHLastSequence = sequence;'),source.index('[FBXCTestDaemonsProxy synthesizeEventWithRecord:'))
        self.assertIn('sequence <= JHHLastSequence',source)
    def test_no_vendor_sdk_download(self):
        self.assertTrue(module.SOURCE_URL.startswith('https://codeload.github.com/appium/'))
        self.assertEqual(len(module.SOURCE_SHA256),64)

if __name__=='__main__': unittest.main()
