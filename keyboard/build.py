"""Build an unsigned iOS16 keyboard IPA. Xcode required only for compilation."""
from pathlib import Path
import hashlib, json, plistlib, shutil, subprocess, sys, zipfile

ROOT = Path(__file__).resolve().parent
VERSION = '1.0.2'
BUILD = '3'

def prepare():
    build = ROOT / 'build'
    build.mkdir(exist_ok=True)
    common = dict(CFBundleDevelopmentRegion='zh_CN', CFBundleExecutable='$(EXECUTABLE_NAME)',
                  CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)', CFBundleInfoDictionaryVersion='6.0',
                  CFBundleName='$(PRODUCT_NAME)', CFBundleShortVersionString=VERSION, CFBundleVersion=BUILD,
                  CFBundlePackageType='APPL', LSRequiresIPhoneOS=True)
    host = dict(common, CFBundleDisplayName='镜好好键盘', UILaunchScreen={}, UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'])
    keyboard = dict(common, CFBundleDisplayName='镜好好键盘', CFBundlePackageType='XPC!',
                    NSExtension=dict(NSExtensionPointIdentifier='com.apple.keyboard-service',
                        NSExtensionPrincipalClass='$(PRODUCT_MODULE_NAME).KeyboardViewController',
                        NSExtensionAttributes=dict(IsASCIICapable=False, PrimaryLanguage='zh-Hans', PrefersRightToLeft=False, RequestsOpenAccess=True)))
    for name, value in [('Host', host), ('Keyboard', keyboard)]:
        with (build/(name+'.plist')).open('wb') as f: plistlib.dump(value, f)
    objects = {}
    def add(identity, **properties):
        key = hashlib.sha256(identity.encode()).hexdigest()[:24].upper(); objects[key] = properties; return key
    host_file = add('hostfile', isa='PBXFileReference', lastKnownFileType='sourcecode.swift', path='../Host/AppDelegate.swift', sourceTree='<group>')
    key_file = add('keyfile', isa='PBXFileReference', lastKnownFileType='sourcecode.swift', path='../Keyboard/KeyboardViewController.swift', sourceTree='<group>')
    listener_file = add('listenerfile', isa='PBXFileReference', lastKnownFileType='sourcecode.swift', path='../Keyboard/KeyboardLoopbackListener.swift', sourceTree='<group>')
    host_product = add('hostproduct', isa='PBXFileReference', explicitFileType='wrapper.application', path='JHHKeyboard.app', sourceTree='BUILT_PRODUCTS_DIR')
    key_product = add('keyproduct', isa='PBXFileReference', explicitFileType='wrapper.app-extension', path='JHHKeyboardExtension.appex', sourceTree='BUILT_PRODUCTS_DIR')
    group = add('group', isa='PBXGroup', children=[host_file,key_file,listener_file,host_product,key_product], sourceTree='<group>')
    def config(name, extension):
        settings = dict(SDKROOT='iphoneos', IPHONEOS_DEPLOYMENT_TARGET='16.0', SWIFT_VERSION='5.0', TARGETED_DEVICE_FAMILY='1,2',
                        CODE_SIGNING_ALLOWED='NO', CLANG_ENABLE_MODULES='YES', PRODUCT_NAME='$(TARGET_NAME)',
                        PRODUCT_BUNDLE_IDENTIFIER='com.jinghaohao.keyboard'+('.extension' if extension else ''),
                        INFOPLIST_FILE=('Keyboard' if extension else 'Host')+'.plist',
                        LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks'],
                        APPLICATION_EXTENSION_API_ONLY='YES' if extension else 'NO', SKIP_INSTALL='YES' if extension else 'NO',
                        SWIFT_OPTIMIZATION_LEVEL='-O')
        value = add(name+'release', isa='XCBuildConfiguration', name='Release', buildSettings=settings)
        return add(name+'configs', isa='XCConfigurationList', buildConfigurations=[value], defaultConfigurationName='Release', defaultConfigurationIsVisible=0)
    def phase(name, files):
        entries=[add(name+str(index)+'entry', isa='PBXBuildFile', fileRef=file) for index,file in enumerate(files)]
        return add(name+'sources', isa='PBXSourcesBuildPhase', buildActionMask=2147483647, files=entries, runOnlyForDeploymentPostprocessing=0)
    key_target = add('keytarget', isa='PBXNativeTarget', name='JHHKeyboardExtension', productName='JHHKeyboardExtension', productReference=key_product,
                     productType='com.apple.product-type.app-extension', buildConfigurationList=config('key',True), buildPhases=[phase('key',[key_file,listener_file])], buildRules=[], dependencies=[])
    dependency = add('dependency', isa='PBXTargetDependency', target=key_target)
    embed_file = add('embedfile', isa='PBXBuildFile', fileRef=key_product, settings=dict(ATTRIBUTES=['RemoveHeadersOnCopy']))
    embed = add('embed', isa='PBXCopyFilesBuildPhase', buildActionMask=2147483647, dstPath='', dstSubfolderSpec=13, files=[embed_file], name='Embed App Extensions', runOnlyForDeploymentPostprocessing=0)
    host_target = add('hosttarget', isa='PBXNativeTarget', name='JHHKeyboard', productName='JHHKeyboard', productReference=host_product,
                     productType='com.apple.product-type.application', buildConfigurationList=config('host',False), buildPhases=[phase('host',[host_file]),embed], buildRules=[], dependencies=[dependency])
    project = add('project', isa='PBXProject', attributes=dict(LastUpgradeCheck='1640'), buildConfigurationList=config('project',False), compatibilityVersion='Xcode 14.0', developmentRegion='zh_CN', hasScannedForEncodings=0, knownRegions=['zh_CN','en'], mainGroup=group, projectDirPath='', projectRoot='', targets=[host_target,key_target])
    path=build/'JHHKeyboard.xcodeproj'; path.mkdir(exist_ok=True)
    # Xcode accepts XML property lists as pbxproj files; no third-party generator.
    with (path/'project.pbxproj').open('wb') as f:
        plistlib.dump(dict(archiveVersion='1', classes={}, objectVersion='56', objects=objects, rootObject=project),f)
    return path

def main():
    project=prepare()
    if '--prepare-only' in sys.argv: print('Project and plists prepared; no compilation performed.'); return
    log=ROOT/'build/xcode-build.log'
    with log.open('w',encoding='utf-8') as f:
        subprocess.run(['xcodebuild','-project',str(project),'-target','JHHKeyboard','-configuration','Release','-sdk','iphoneos',
                        'CONFIGURATION_BUILD_DIR='+str(ROOT/'build/products'), 'CODE_SIGNING_ALLOWED=NO','build'], stdout=f,stderr=subprocess.STDOUT,check=True)
    app=ROOT/'build/products/JHHKeyboard.app'
    extension=app/'PlugIns/JHHKeyboardExtension.appex'
    assert (extension/'JHHKeyboardExtension').is_file()
    assert plistlib.loads((extension/'Info.plist').read_bytes())['NSExtension']['NSExtensionAttributes']['RequestsOpenAccess']
    # Give the Windows re-signer a complete Apple-generated signature layout.
    # This is ad-hoc integrity signing, with no Apple account/certificate/profile.
    # Sign inside out and require both verification checks before making an IPA.
    with log.open('a',encoding='utf-8') as f:
        for bundle in (extension, app):
            subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(bundle)],
                           stdout=f, stderr=subprocess.STDOUT, check=True)
        for bundle in (extension, app):
            subprocess.run(['codesign', '--verify', '--strict', '--verbose=2', str(bundle)],
                           stdout=f, stderr=subprocess.STDOUT, check=True)
    out=ROOT/'artifacts'; out.mkdir(exist_ok=True)
    ipa=out/'MirrorGoodGood-Keyboard-iOS16-signing-check2.ipa'
    with zipfile.ZipFile(ipa,'w',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(app.rglob('*')):
            if p.is_file() and p.suffix != '.dSYM': z.write(p,'Payload/JHHKeyboard.app/'+p.relative_to(app).as_posix())
    checksum=hashlib.sha256(ipa.read_bytes()).hexdigest()
    (out/'SHA256SUMS.txt').write_text(checksum+'  '+ipa.name+'\n',encoding='utf-8')
    (out/'build-result.json').write_text(json.dumps(dict(unsigned=False,minimum_ios='16.0',keyboard_extension_embedded=True,version=VERSION,build=BUILD,component_revision='phone-keyboard-r12',
        signature_kind='ad-hoc-integrity-only',apple_identity_signed=False,personal_signing_required=True,
        codesign_strict_verified=['JHHKeyboardExtension','JHHKeyboard'],
        signed_installation_verified=False,physical_input_tested=False,sha256=checksum),indent=2),encoding='utf-8')
    print('Ad-hoc integrity checks passed. Personal signing and phone verification still required.')

if __name__ == '__main__': main()
