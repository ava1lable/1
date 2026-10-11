"""Pinned iloader USB-only installation experiment; no signing bypasses."""
from pathlib import Path
import hashlib
import json
import sys

UPSTREAM = 'dc396af059fd46982062cd8fc90252d7e27085e9'

def replace_once(path, old, new):
    text = path.read_text(encoding='utf-8')
    if text.count(old) != 1:
        raise ValueError('upstream_anchor_mismatch: ' + path.name)
    path.write_text(text.replace(old, new), encoding='utf-8', newline='\n')

def patch(root):
    device = root / 'src-tauri/src/device.rs'
    pairing = root / 'src-tauri/src/pairing.rs'
    replace_once(pairing, '''    lc.set_value(
        "EnableWifiDebugging",
        true.into(),
        Some("com.apple.mobile.wireless_lockdown"),
    )
    .await
    .map_err(|e| {
        AppError::LockdownPairing("Failed to enable wifi debugging".into(), e.to_string())
    })?;

''', '''    // USB validation fork: installation needs only the existing trusted USB session.
    // Do not change Wi-Fi debugging or any other device settings.

''')
    replace_once(pairing,
        'if is_ios_version_below(device.version.as_str(), 17, 4) {',
        'if device.connection_type == "USB" || is_ios_version_below(device.version.as_str(), 17, 4) {')
    replace_once(device, '''    let device_info_futures: Vec<_> = devs
        .iter()
        .map(|d| {''', '''    let device_info_futures: Vec<_> = devs
        .iter()
        .filter(|d| matches!(d.connection_type, Connection::Usb))
        .map(|d| {''')
    replace_once(device, '''    let mut usbmuxd = get_usbmuxd().await?;

    let token = tokio_util::sync::CancellationToken::new();''', '''    if device.as_ref().unwrap().connection_type != "USB" {
        return Err(AppError::DeviceComs("USB validation requires a USB device".into()));
    }
    // A failed new selection must not leave the previous installation target armed.
    *device_state.lock().unwrap() = None;
    let mut usbmuxd = get_usbmuxd().await?;

    let token = tokio_util::sync::CancellationToken::new();''')
    replace_once(device, '''    let device = connection
        .get_device(&device_info.udid)
        .await
        .map_err(|e| {
            AppError::DeviceComsWithMessage("Failed to get device".into(), e.to_string())
        })?;''', '''    let device = connection
        .get_devices()
        .await
        .map_err(|e| {
            AppError::DeviceComsWithMessage("Failed to get USB device".into(), e.to_string())
        })?
        .into_iter()
        .find(|entry| entry.device_id == device_info.id
            && entry.udid == device_info.udid
            && matches!(entry.connection_type, Connection::Usb))
        .ok_or_else(|| AppError::DeviceComs("Selected USB connection is no longer available".into()))?;''')
    config_path = root / 'src-tauri/tauri.conf.json'
    config = json.loads(config_path.read_text(encoding='utf-8'))
    config['identifier'] = 'com.jinghaohao.iloader-usb-validation'
    config['app']['windows'][0]['title'] = 'iloader USB validation 1 (unofficial)'
    config['bundle']['createUpdaterArtifacts'] = False
    config_path.write_text(json.dumps(config, indent=2) + '\n', encoding='utf-8')
    note = root / 'USB-VALIDATION-NOTICE.txt'
    note.write_text(
        'Unofficial USB validation fork of iloader 2.3.6.\n'
        'Official project: https://github.com/nab138/iloader\n'
        'Official website: https://iloader.app/\n'
        'Not endorsed by the upstream authors.\n'
        'Pinned upstream commit: ' + UPSTREAM + '\n'
        'Only USB devices are eligible; no automatic Wi-Fi debugging or remote pairing.\n'
        'Apple authentication, certificates, signing, and protected storage are upstream implementations.\n'
        'This build does not bypass Apple signing or device trust checks.\n'
        'Keyboard load and visible input are unverified until a real-device test.\n', encoding='utf-8')
    # The lock file binds the separate signing implementation checked locally.
    lock = (root / 'src-tauri/Cargo.lock').read_text(encoding='utf-8')
    expected = 'name = "apple-codesign-quick"\nversion = "0.1.0"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\nchecksum = "519defc726db80b8a43836bbd6f69eb606a42783db799716a103436042593f0b"'
    assert expected in lock
    assert 'EnableWifiDebugging' not in pairing.read_text(encoding='utf-8')
    report = {'upstream_commit': UPSTREAM, 'revision': 1,
              'signer_changed': False, 'apple_authentication_changed': False,
              'usb_only': True, 'wifi_debugging_written': False,
              'remote_pairing_for_usb': False, 'phone_input_sent': False,
              'modified_files': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in (device, pairing, config_path, note)}}
    (root / 'usb-patch-verification.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report))

if __name__ == '__main__':
    patch(Path(sys.argv[1]).resolve())
