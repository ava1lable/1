"""Reproducible unsigned WDA+Photos build; never accepts Apple credentials."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import platform
import shutil
import struct
import subprocess
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent
SOURCE_URL = 'https://codeload.github.com/appium/WebDriverAgent/zip/refs/tags/v12.0.0'
SOURCE_SHA256 = '9c435b122b93d0f88cbf06b65eec5756d30c12d90a73b2d1c8caeef00edf540e'
PHOTO_USAGE = '将你在镜好好电脑端选择的图片保存到手机相册；不读取已有照片。'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def verify_macho(path):
    data = path.read_bytes()
    if len(data) < 32 or struct.unpack_from('<II', data) != (0xfeedfacf, 0x0100000c):
        raise RuntimeError('Expected a compiled arm64 Mach-O: ' + path.name)
    commands = struct.unpack_from('<I', data, 16)[0]; offset = 32; platform_id = None
    for _ in range(commands):
        if offset + 8 > len(data): raise RuntimeError('Truncated Mach-O')
        kind, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > len(data): raise RuntimeError('Invalid Mach-O command')
        if kind == 0x32 and size >= 24: platform_id = struct.unpack_from('<I', data, offset + 8)[0]
        offset += size
    if platform_id != 2: raise RuntimeError('Expected iOS device Mach-O, not a Simulator binary')

def replace_once(path, before, after):
    text = path.read_text(encoding='utf-8')
    if text.count(before) != 1:
        raise RuntimeError('Pinned source anchor changed: ' + path.name)
    path.write_text(text.replace(before, after), encoding='utf-8')

def prepare(archive=None, output=None):
    output = Path(output) if output else ROOT / 'build'
    output.mkdir(parents=True, exist_ok=True)
    source = output / 'WebDriverAgent-12.0.0'
    if source.exists():
        raise RuntimeError('Use a fresh build directory; existing sources are never overwritten.')
    archive = Path(archive) if archive else output / 'upstream.zip'
    if not archive.exists():
        with urllib.request.urlopen(SOURCE_URL, timeout=60) as response:
            archive.write_bytes(response.read())
    if digest(archive) != SOURCE_SHA256:
        raise RuntimeError('Upstream source checksum mismatch')
    with zipfile.ZipFile(archive) as z:
        for name in z.namelist():
            parts = Path(name).parts
            if not parts or parts[0] != source.name or '..' in parts or Path(name).is_absolute() or '\\' in name:
                raise RuntimeError('Unsafe upstream archive path')
        z.extractall(output)
    commands = source / 'WebDriverAgentLib/Commands'
    for path in (ROOT / 'patches').glob('FBJHHPhotoCommands.*'):
        shutil.copy2(path, commands / path.name)
    # Compile through an existing source unit: avoids generated Xcode project IDs.
    custom = commands / 'FBCustomCommands.m'
    with custom.open('a', encoding='utf-8') as f:
        f.write('\n#if TARGET_OS_IOS\n#import "FBJHHPhotoCommands.m"\n#endif\n')
    web = source / 'WebDriverAgentLib/Routing/FBWebServer.m'
    replace_once(web, 'NSString *bindingIP = FBConfiguration.bindingIPAddress;',
                 'NSString *bindingIP = @"127.0.0.1"; // JHH: USB-only loopback listener')
    replace_once(web, '[FBLogger verboseLog:routeParams.description];',
                 '[FBLogger verboseLog:routeParams.URL.path]; // Never log input or image bodies')
    info = source / 'WebDriverAgentRunner/Info.plist'
    data = plistlib.loads(info.read_bytes())
    data['NSPhotoLibraryAddUsageDescription'] = PHOTO_USAGE
    info.write_bytes(plistlib.dumps(data))
    return source, output

def package_app(app, output):
    app, output = Path(app), Path(output)
    if not app.is_dir() or app.suffix != '.app':
        raise RuntimeError('Missing compiled iPhone app')
    data = plistlib.loads((app / 'Info.plist').read_bytes())
    if data.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise RuntimeError('Only a real-device iPhoneOS build may be packaged')
    data.update(NSPhotoLibraryAddUsageDescription=PHOTO_USAGE, CFBundleDisplayName='镜好好组件',
                JHHPhotoAPIVersion=1, JHHComponentVersion='1.11.15-preview.1')
    (app / 'Info.plist').write_bytes(plistlib.dumps(data))
    test_bundles = list((app / 'PlugIns').glob('*.xctest'))
    if len(test_bundles) != 1:
        raise RuntimeError('Expected exactly one nested XCTest bundle')
    # Also install the usage description in the nested test bundle for XCTest hosts.
    test_info = test_bundles[0] / 'Info.plist'
    test_data = plistlib.loads(test_info.read_bytes())
    test_data['NSPhotoLibraryAddUsageDescription'] = PHOTO_USAGE
    test_info.write_bytes(plistlib.dumps(test_data))
    verify_macho(app / data['CFBundleExecutable'])
    verify_macho(test_bundles[0] / test_data['CFBundleExecutable'])
    libraries = list(app.rglob('WebDriverAgentLib.framework/WebDriverAgentLib'))
    if len(libraries) != 1 or b'MirrorGoodGood-WDA-Photos' not in libraries[0].read_bytes():
        raise RuntimeError('Compiled WDA library does not contain the Photos extension')
    verify_macho(libraries[0])
    output.mkdir(parents=True, exist_ok=True)
    ipa = output / 'MirrorGoodGood-WDA-Photos-v1.11.15-unsigned.ipa'
    if ipa.exists():
        raise RuntimeError('Existing IPA is preserved; use a new output directory')
    files = []
    with zipfile.ZipFile(ipa, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for path in sorted(app.rglob('*')):
            relative = path.relative_to(app)
            if any(part.endswith('.dSYM') or part == '_CodeSignature' for part in relative.parts) or path.name == 'embedded.mobileprovision':
                continue
            if path.is_symlink():
                raise RuntimeError('Unexpected app symlink; inspect the build before packaging')
            if path.is_file():
                name = 'Payload/' + app.name + '/' + relative.as_posix()
                z.write(path, name); files.append({'path':name, 'sha256':digest(path), 'bytes':path.stat().st_size})
    with zipfile.ZipFile(ipa) as z:
        if z.testzip() is not None:
            raise RuntimeError('IPA CRC verification failed')
        for item in files:
            if hashlib.sha256(z.read(item['path'])).hexdigest() != item['sha256']:
                raise RuntimeError('IPA entry verification failed')
    result = {'component':'MirrorGoodGood-WDA-Photos', 'version':'1.11.15-preview.1', 'apiVersion':1,
              'upstream':'WebDriverAgent 12.0.0', 'upstream_source_sha256':SOURCE_SHA256,
              'signed':False, 'physical_phone_tested':False, 'ipa':ipa.name, 'sha256':digest(ipa), 'files':files}
    result['patches'] = {p.name:digest(p) for p in sorted((ROOT / 'patches').glob('*')) if p.is_file()}
    for name in ['LICENSE', 'README.md']:
        shutil.copy2(ROOT / name, output / name)
    prepared = ROOT / 'build/WebDriverAgent-12.0.0'
    if prepared.is_dir():
        shutil.copy2(prepared / 'LICENSE', output / 'WebDriverAgent-LICENSE')
        with zipfile.ZipFile(output / 'corresponding-source.zip', 'w', zipfile.ZIP_DEFLATED) as z:
            for path in sorted(prepared.rglob('*')):
                if path.is_file(): z.write(path, 'WebDriverAgent-12.0.0/' + path.relative_to(prepared).as_posix())
            for path in [ROOT / 'build.py', ROOT / 'LICENSE', *(ROOT / 'patches').glob('*')]:
                if path.is_file(): z.write(path, 'mirror-photos/' + path.relative_to(ROOT).as_posix())
    (output / 'build-result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    (output / 'SHA256SUMS.txt').write_text(result['sha256'] + '  ' + ipa.name + '\n', encoding='utf-8')
    return result

def build(source, output):
    if platform.system() != 'Darwin':
        raise RuntimeError('Compilation requires macOS with Xcode; --prepare-only works on Windows.')
    derived = output / 'derived'
    command = ['xcodebuild', 'build-for-testing', '-project', str(source / 'WebDriverAgent.xcodeproj'),
               '-scheme', 'WebDriverAgentRunner', '-configuration', 'Debug', '-sdk', 'iphoneos',
               '-destination', 'generic/platform=iOS', '-derivedDataPath', str(derived),
               'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'IPHONEOS_DEPLOYMENT_TARGET=16.0',
               'ARCHS=arm64',
               'OTHER_LDFLAGS=$(inherited) -framework Photos -framework ImageIO']
    log = output / 'xcode-build.log'
    with log.open('w', encoding='utf-8') as f:
        result = subprocess.run(command, cwd=source, stdout=f, stderr=subprocess.STDOUT)
    if result.returncode:
        print('\n'.join(log.read_text(encoding='utf-8', errors='replace').splitlines()[-90:]))
        raise RuntimeError('Xcode compilation failed; see xcode-build.log')
    apps = list((derived / 'Build/Products/Debug-iphoneos').glob('WebDriverAgentRunner-Runner.app'))
    if len(apps) != 1:
        raise RuntimeError('Xcode did not produce the expected runner app')
    return package_app(apps[0], ROOT / 'artifacts')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--archive'); parser.add_argument('--output'); parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    source, output = prepare(args.archive, args.output)
    if args.prepare_only:
        print('Pinned source and Photos extension prepared; not compiled.')
    else:
        result = build(source, output)
        print(json.dumps({k:v for k,v in result.items() if k != 'files'}, ensure_ascii=False))
