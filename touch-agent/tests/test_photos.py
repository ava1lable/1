from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class PhotosBoundaries(unittest.TestCase):
 def test_only_add_permission_and_no_album_read(self):
  s=(ROOT/'patches/FBJHHPhotoCommands.m').read_text()
  self.assertIn('PHAccessLevelAddOnly',s)
  for x in ('fetchAssets','deleteAssets','PHAccessLevelReadWrite','NSLog','request.arguments.description'):self.assertNotIn(x,s)
 def test_crash_uncertainty_and_single_commit(self):
  s=(ROOT/'patches/FBJHHPhotoCommands.m').read_text()
  self.assertIn('job[@"state"] = @"unknown"',s)
  self.assertIn('@[@"saved", @"saving", @"validating", @"unknown"]',s)
  self.assertEqual(s.count('performChanges:'),1)
  self.assertIn('JHHValidImage(snapshot)',s)
  self.assertIn('CC_SHA256_Final',s)
 def test_registration_and_privacy_packaging(self):
  s=(ROOT/'build.py').read_text()
  self.assertIn('FBJHHPhotoCommands.class',s)
  self.assertIn('NSPhotoLibraryAddUsageDescription',s)
  self.assertIn('-framework Photos -framework ImageIO',s)
  self.assertIn('photo-upload-v1',s)
 def test_bounded_jobs_chunks_and_order(self):
  s=(ROOT/'patches/FBJHHPhotoCommands.m').read_text()
  for x in ('64 * 1024 * 1024','256 * 1024','JHHJobs.count >= 512','isEqual:job[@"received"]','chunk_order','JHHInteger(length,JHHMaxBytes)','CGImageSourceGetType'):self.assertIn(x,s)
if __name__=='__main__':unittest.main()
