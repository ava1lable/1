"""Pinned public-source touch agent. No signing credentials or vendor binaries."""
from pathlib import Path
import argparse
import hashlib
import json
import platform
import plistlib
import shutil
import stat
import struct
import subprocess
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent
SOURCE_URL = 'https://codeload.github.com/appium/WebDriverAgent/zip/refs/tags/v12.0.0'
SOURCE_SHA256 = '9c435b122b93d0f88cbf06b65eec5756d30c12d90a73b2d1c8caeef00edf540e'
VERSION = '1.9.1'

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def replace_once(path, before, after):
    text = path.read_text(encoding='utf-8')
    if text.count(before) != 1:
        raise RuntimeError('Pinned source anchor changed: ' + path.name)
    path.write_text(text.replace(before, after), encoding='utf-8')

def extract_verified(archive, output):
    if digest(archive) != SOURCE_SHA256:
        raise RuntimeError('Public upstream archive checksum mismatch')
    output = output.resolve()
    with zipfile.ZipFile(archive) as z:
        if sum(f.file_size for f in z.infolist()) > 100_000_000:
            raise RuntimeError('Unexpected upstream archive size')
        for f in z.infolist():
            path = Path(f.filename)
            if not path.parts or path.parts[0] != 'WebDriverAgent-12.0.0' or '\\' in f.filename or \
                    not (output / path).resolve().is_relative_to(output) or stat.S_ISLNK(f.external_attr >> 16):
                raise RuntimeError('Unsafe upstream archive entry')
        z.extractall(output)

def prepare(archive=None, output=None):
    output = Path(output) if output else ROOT / 'build'
    output.mkdir(parents=True, exist_ok=True)
    source = output / 'WebDriverAgent-12.0.0'
    if source.exists():
        raise RuntimeError('Existing build sources are preserved; choose a fresh build directory')
    archive = Path(archive) if archive else output / 'upstream.zip'
    if not archive.exists():
        with urllib.request.urlopen(SOURCE_URL, timeout=60) as r:
            archive.write_bytes(r.read())
    extract_verified(archive, output)
    commands = source / 'WebDriverAgentLib/Commands'
    for patch in (ROOT / 'patches').glob('*'):
        shutil.copy2(patch, commands / patch.name)
    with (commands / 'FBCustomCommands.m').open('a', encoding='utf-8') as f:
        f.write('\n#if TARGET_OS_IOS\n#import "JHHControlCommands.m"\n#import "FBJHHPhotoCommands.m"\n#endif\n')
    web = source / 'WebDriverAgentLib/Routing/FBWebServer.m'
    replace_once(web, '#import "FBCommandHandler.h"', '#import "FBCommandHandler.h"\n#import "../Commands/JHHControlCommands.h"\n#import "../Commands/FBJHHPhotoCommands.h"')
    text = web.read_text(encoding='utf-8')
    start = text.index('  NSArray *handlersClasses = FBClassesThatConformsToProtocol')
    end = text.index('\n}', start)
    text = text[:start] + '  return @[JHHControlCommands.class, FBJHHPhotoCommands.class];' + text[end:]
    web.write_text(text, encoding='utf-8')
    replace_once(web, '  [self initScreenshotsBroadcaster];', '  // Stage 1: no screenshot broadcaster.')
    replace_once(web, '  [self registerServerKeyRouteHandlers];', '  // Stage 1: no calibration, shutdown or generic WDA routes.')
    replace_once(web, 'NSRange serverPortRange = FBConfiguration.bindingPortRange;', 'NSRange serverPortRange = NSMakeRange(8100, 1);')
    replace_once(web, 'NSString *bindingIP = FBConfiguration.bindingIPAddress;', 'NSString *bindingIP = @"127.0.0.1"; // USB-only')
    replace_once(web, '[FBLogger verboseLog:routeParams.description];', '[FBLogger verboseLog:routeParams.URL.path];')
    replace_once(web, '[self.server setDefaultHeader:@"Access-Control-Allow-Origin" value:@"*"];', '// No cross-origin browser API.')
    runner = source / 'WebDriverAgentRunner/UITestingUITests.m'
    replace_once(runner, '  [FBConfiguration configureDefaultKeyboardPreferences];',
        '  // Stage 1 does not change keyboard preferences.\n  [FBConfiguration setWaitForIdleTimeout:0];\n  [FBConfiguration setAnimationCoolOffTimeout:0];')
    info_path=source/'WebDriverAgentRunner/Info.plist'
    info=plistlib.loads(info_path.read_bytes())
    info['NSPhotoLibraryAddUsageDescription']='将你在镜好好电脑端选择的图片保存到相册；不读取已有照片。'
    info_path.write_bytes(plistlib.dumps(info))
    return source, output

def macho_architectures(data):
    fat_formats = {b'\xca\xfe\xba\xbe': ('>', False), b'\xbe\xba\xfe\xca': ('<', False),
                   b'\xca\xfe\xba\xbf': ('>', True), b'\xbf\xba\xfe\xca': ('<', True)}
    slices = []
    if data[:4] in fat_formats:
        endian, wide = fat_formats[data[:4]]
        if len(data) < 8: raise RuntimeError('Truncated universal Mach-O')
        count = struct.unpack_from(endian + 'I', data, 4)[0]
        entry_size = 32 if wide else 20
        table_end = 8 + count * entry_size
        if not 0 < count <= 32 or table_end > len(data): raise RuntimeError('Invalid architecture table')
        for index in range(count):
            fields = struct.unpack_from(endian + ('IIQQII' if wide else 'IIIII'), data, 8 + index * entry_size)
            cpu, subtype, start, size, alignment = fields[:5]
            if cpu != 0x0100000c or alignment > 32 or start < table_end or size < 32 or start + size > len(data):
                raise RuntimeError('Invalid iPhone architecture slice')
            if start % (1 << alignment) or any(start < b and start + size > a for a, b, *_ in slices):
                raise RuntimeError('Overlapping or misaligned architecture slices')
            slices.append((start, start + size, cpu, subtype))
    else:
        slices.append((0, len(data), 0x0100000c, None))
    result = []
    for start, end, expected_cpu, expected_subtype in slices:
        section = data[start:end]
        if len(section) < 32 or struct.unpack_from('<II', section) != (0xfeedfacf, expected_cpu):
            raise RuntimeError('Expected a compiled arm64 Mach-O')
        subtype = struct.unpack_from('<I', section, 8)[0]
        if expected_subtype is not None and subtype != expected_subtype:
            raise RuntimeError('Architecture subtype does not match universal header')
        commands, command_bytes = struct.unpack_from('<II', section, 16)
        limit = 32 + command_bytes; offset = 32; platform_id = None
        if not 0 < commands <= 65536 or limit > len(section): raise RuntimeError('Invalid load command bounds')
        for _ in range(commands):
            if offset + 8 > limit: raise RuntimeError('Truncated Mach-O')
            kind, size = struct.unpack_from('<II', section, offset)
            if size < 8 or offset + size > limit: raise RuntimeError('Invalid Mach-O command')
            if kind == 0x32 and size >= 24: platform_id = struct.unpack_from('<I', section, offset + 8)[0]
            elif kind == 0x25 and size >= 16: platform_id = 2  # LC_VERSION_MIN_IPHONEOS
            offset += size
        if offset != limit or platform_id != 2:
            raise RuntimeError('Expected iOS device Mach-O, not a Simulator binary')
        result.append({'cpu': 'arm64', 'subtype': subtype, 'platform': 'iOS-device'})
    return result

def verify_macho(path):
    try: return macho_architectures(path.read_bytes())
    except RuntimeError as error: raise RuntimeError(str(error) + ': ' + path.name) from error

def verify_device_binary(path):
    return verify_macho(path)

def bundle_identifiers(main_id):
    return main_id, main_id + '.WebDriverAgentRunner'

def allowed_payload(path):
    return not any(p.endswith('.dSYM') or p == '_CodeSignature' for p in path.parts) and \
        path.name != 'embedded.mobileprovision'

def package(app, source, artifacts):
    app, artifacts = Path(app), Path(artifacts)
    info_file = app / 'Info.plist'
    info = plistlib.loads(info_file.read_bytes())
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise RuntimeError('Expected iPhoneOS app')
    tests = list((app / 'PlugIns').glob('*.xctest'))
    if len(tests) != 1: raise RuntimeError('Expected one XCTest bundle')
    nested = tests[0]
    test_info_file = nested / 'Info.plist'
    test_info = plistlib.loads(test_info_file.read_bytes())
    main_id, test_id = bundle_identifiers('com.jinghaohao.touch.runner')
    info.update(CFBundleIdentifier=main_id, CFBundleDisplayName='镜好好触控', CFBundleName='JHHTouchAgent',
                CFBundleShortVersionString=VERSION, CFBundleVersion='11', MinimumOSVersion='16.0',
                JHHComponent='JHH-Touch-Agent', JHHProtocolVersion=1)
    test_info.update(CFBundleIdentifier=test_id, CFBundleShortVersionString=VERSION, CFBundleVersion='11')
    for data in (info, test_info):
        data.pop('NSPhotoLibraryUsageDescription', None)
        data['NSPhotoLibraryAddUsageDescription'] = '将你在镜好好电脑端选择的图片保存到相册；不读取已有照片。'
    info_file.write_bytes(plistlib.dumps(info))
    test_info_file.write_bytes(plistlib.dumps(test_info))
    binaries = [app / info['CFBundleExecutable'], nested / test_info['CFBundleExecutable']]
    libraries = list(app.rglob('WebDriverAgentLib.framework/WebDriverAgentLib'))
    if len(libraries) != 1 or b'JHH-Touch-Agent' not in libraries[0].read_bytes():
        raise RuntimeError('Touch agent implementation missing from compiled framework')
    for binary in binaries + libraries: verify_device_binary(binary)
    artifacts.mkdir(parents=True, exist_ok=True)
    ipa = artifacts / ('MirrorGoodGood-Touch-Agent-v' + VERSION + '-iOS16-unsigned.ipa')
    if ipa.exists(): raise RuntimeError('Existing IPA preserved')
    files = []
    with zipfile.ZipFile(ipa, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for path in sorted(app.rglob('*')):
            rel = path.relative_to(app)
            if not allowed_payload(rel): continue
            if path.is_symlink(): raise RuntimeError('Unexpected symlink in app')
            if path.is_file():
                name = 'Payload/' + app.name + '/' + rel.as_posix()
                z.write(path, name)
                files.append({'path':name, 'sha256':digest(path), 'bytes':path.stat().st_size})
    with zipfile.ZipFile(ipa) as z:
        if z.testzip(): raise RuntimeError('IPA CRC check failed')
        for f in files:
            if hashlib.sha256(z.read(f['path'])).hexdigest() != f['sha256']:
                raise RuntimeError('IPA entry checksum mismatch')
    codec=ROOT/'json-codec-proof.json'
    if not codec.exists():raise RuntimeError('Actual Foundation JSON test proof required')
    shutil.copy2(codec,artifacts/codec.name)
    shutil.copy2(ROOT / 'LICENSE', artifacts / 'LICENSE')
    shutil.copy2(ROOT / 'README.md', artifacts / 'README.md')
    shutil.copy2(source / 'LICENSE', artifacts / 'WebDriverAgent-LICENSE')
    with zipfile.ZipFile(artifacts / 'corresponding-source.zip', 'w', zipfile.ZIP_DEFLATED) as z:
        for path in sorted(source.rglob('*')):
            if path.is_file(): z.write(path, 'WebDriverAgent-12.0.0/' + path.relative_to(source).as_posix())
        for path in [ROOT / 'build.py', ROOT / 'LICENSE', *(ROOT / 'patches').glob('*')]:
            if path.is_file(): z.write(path, 'touch-agent/' + path.relative_to(ROOT).as_posix())
    result = {'component':'JHH-Touch-Agent','version':VERSION,'protocol':1,'upstream':'Appium WebDriverAgent 12.0.0',
              'upstreamSha256':SOURCE_SHA256,'bundleIdentifier':main_id,'testBundleIdentifier':test_id,
              'features':['tap','swipe','native-keyboard-v1','native-keyboard-batch-v1','geometry-cache-v1','native-candidate-numbers-v1','keyboard-standard-snapshot-v1','committed-text-v1','text-receipt-v1','photo-upload-v1'],'signed':False,'phoneTested':False,'ipa':ipa.name,'sha256':digest(ipa),
              'files':files,'patches':{p.name:digest(p) for p in (ROOT/'patches').glob('*')}}
    (artifacts / 'build-result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    (artifacts / 'SHA256SUMS.txt').write_text(result['sha256']+'  '+ipa.name+'\n',encoding='utf-8')
    return result

def build(source, output):
    if platform.system() != 'Darwin': raise RuntimeError('Xcode compilation requires macOS')
    derived = output / 'derived'
    command = ['xcodebuild','build-for-testing','-project',str(source/'WebDriverAgent.xcodeproj'),
               '-scheme','WebDriverAgentRunner','-configuration','Release','-sdk','iphoneos',
               '-destination','generic/platform=iOS','-derivedDataPath',str(derived),
               'CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','IPHONEOS_DEPLOYMENT_TARGET=16.0',
               'ARCHS=arm64','PRODUCT_BUNDLE_IDENTIFIER=com.jinghaohao.touch','DEVELOPMENT_TEAM=','OTHER_LDFLAGS=$(inherited) -framework Photos -framework ImageIO']
    log = output / 'xcode-build.log'
    with log.open('w',encoding='utf-8') as f: result = subprocess.run(command,cwd=source,stdout=f,stderr=subprocess.STDOUT)
    if result.returncode:
        print('\n'.join(log.read_text(encoding='utf-8',errors='replace').splitlines()[-80:]))
        raise RuntimeError('Xcode compilation failed')
    apps = list((derived/'Build/Products/Release-iphoneos').glob('WebDriverAgentRunner-Runner.app'))
    if len(apps)!=1: raise RuntimeError('Expected compiled runner app')
    return package(apps[0],source,ROOT/'artifacts')

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--archive'); parser.add_argument('--output'); parser.add_argument('--prepare-only',action='store_true')
    args=parser.parse_args()
    source,output=prepare(args.archive,args.output)
    if args.prepare_only: print('Public source and tap/swipe patches prepared; not compiled')
    else:
        result=build(source,output)
        print(json.dumps({k:v for k,v in result.items() if k!='files'},ensure_ascii=False))
