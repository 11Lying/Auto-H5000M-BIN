#!/usr/bin/env bash
# Build selected IPKs, run OpenWrt's real rootfs package transaction, and audit
# ownership of every IPK in that exact transaction. No firmware image is built.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${SOURCE_DIR:-immortalwrt}"
REPORT_DIR="${REPORT_DIR:-$ROOT_DIR/rootfs-preflight}"
THREADS="${THREADS:-$(nproc 2>/dev/null || echo 2)}"
PACKAGE_TIMEOUT="${PACKAGE_TIMEOUT:-28800}"

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

run_timed() {
  local label="$1"
  shift
  log "$label (timeout ${PACKAGE_TIMEOUT}s)"
  timeout --foreground "$PACKAGE_TIMEOUT" "$@"
}

main() {
  cd "$ROOT_DIR"
  rm -rf "$REPORT_DIR"
  mkdir -p "$REPORT_DIR"

  log 'Preparing the corrected H5000M configuration and feeds'
  bash scripts/local-build.sh --config-only |& tee "$REPORT_DIR/configure.log"

  cd "$ROOT_DIR/$SOURCE_DIR"
  [ -f .config ] || die 'Configuration was not generated'
  grep -qx 'CONFIG_PACKAGE_luci-app-qmodem-next=y' .config || die 'QModem Next is absent from final config'
  grep -qx 'CONFIG_PACKAGE_luci-app-openclash=y' .config || die 'OpenClash is absent from final config'
  grep -q '+libwebsockets-full' feeds/qmodem/application/voipd/Makefile || die 'QModem VoIP does not select libwebsockets-full'
  if grep -q '+libwebsockets-mbedtls' feeds/qmodem/application/voipd/Makefile; then
    die 'QModem VoIP still selects libwebsockets-mbedtls'
  fi
  cp .config "$REPORT_DIR/build.config"

  # package/compile needs the host tools and cross toolchain first. This is the
  # same preparation used by the firmware path, but stops before image creation.
  log 'Preparing host tools and target toolchain'
  run_timed 'Building host tools and target toolchain' make -j"$THREADS" tools/install toolchain/install |& tee "$REPORT_DIR/toolchain.log"

  # This target builds package archives and their dependencies, but does not
  # invoke image generation. package/install below performs the same opkg rootfs
  # transaction used by a firmware build.
  run_timed 'Building selected IPKs only' make -j"$THREADS" package/compile |& tee "$REPORT_DIR/package-compile.log"

  set +e
  run_timed 'Running real rootfs package-install transaction' make -j1 V=s package/install |& tee "$REPORT_DIR/package-install.log"
  local install_status=${PIPESTATUS[0]}
  set -e

  local install_list='tmp/opkg_install_list'
  [ -s "$install_list" ] || die 'OpenWrt did not generate the rootfs opkg install list'
  cp "$install_list" "$REPORT_DIR/opkg-install-list.txt"

  log 'Auditing package closure and IPK file ownership'
  python3 - "$install_list" "$REPORT_DIR" <<'PYTHON'
import collections
import pathlib
import subprocess
import sys

install_list = pathlib.Path(sys.argv[1])
report_dir = pathlib.Path(sys.argv[2])
ipks = []
seen = set()
for word in install_list.read_text().split():
    path = pathlib.Path(word)
    if path.suffix != '.ipk':
        raise SystemExit(f'Unexpected entry in opkg install list: {word}')
    if not path.is_file():
        raise SystemExit(f'IPK listed for rootfs transaction is missing: {path}')
    resolved = str(path.resolve())
    if resolved not in seen:
        seen.add(resolved)
        ipks.append(path)

def archive_member(ipk, prefix):
    members = subprocess.run(['ar', 't', str(ipk)], check=True, text=True,
                             stdout=subprocess.PIPE).stdout.splitlines()
    found = [member for member in members if member.startswith(prefix)]
    if len(found) != 1:
        raise RuntimeError(f'{ipk}: expected one {prefix} archive, found {found}')
    return found[0]

def archive_bytes(ipk, member):
    return subprocess.run(['ar', 'p', str(ipk), member], check=True,
                          stdout=subprocess.PIPE).stdout

def tar_command(member, operation, member_name=None):
    if member.endswith('.gz'):
        mode = {'list': '-tzf', 'extract': '-xOzf'}[operation]
        args = ['tar', mode, '-']
    elif member.endswith('.xz'):
        mode = {'list': '-tJf', 'extract': '-xOJf'}[operation]
        args = ['tar', mode, '-']
    elif member.endswith('.zst'):
        mode = {'list': '-tf', 'extract': '-xOf'}[operation]
        args = ['tar', '--zstd', mode, '-']
    else:
        mode = {'list': '-tf', 'extract': '-xOf'}[operation]
        args = ['tar', mode, '-']
    if member_name is not None:
        args.append(member_name)
    return args

def package_name(ipk):
    member = archive_member(ipk, 'control.tar')
    control = subprocess.run(tar_command(member, 'extract', './control'),
                             input=archive_bytes(ipk, member), check=True,
                             stdout=subprocess.PIPE).stdout.decode(errors='replace')
    for line in control.splitlines():
        if line.startswith('Package: '):
            return line.partition(': ')[2].strip()
    raise RuntimeError(f'{ipk}: control metadata has no Package field')

def package_paths(ipk):
    member = archive_member(ipk, 'data.tar')
    listing = subprocess.run(tar_command(member, 'list'), input=archive_bytes(ipk, member),
                             check=True, stdout=subprocess.PIPE).stdout.decode(errors='replace')
    paths = []
    for raw in listing.splitlines():
        path = raw.removeprefix('./').rstrip('/')
        if path:
            paths.append(path)
    return paths

names = {}
owners = collections.defaultdict(list)
for ipk in ipks:
    name = package_name(ipk)
    if name in names:
        raise SystemExit(f'Duplicate package name in rootfs transaction: {name}: {names[name]} and {ipk}')
    names[name] = str(ipk)
    for path in package_paths(ipk):
        owners[path].append(name)

required = {'libwebsockets-full', 'ttyd', 'qmodem-voip', 'qmodem-sipd',
            'luci-app-qmodem-next', 'luci-app-openclash'}
missing = sorted(required - names.keys())
forbidden = sorted({'libwebsockets-mbedtls'} & names.keys())
collisions = {path: sorted(set(providers)) for path, providers in owners.items()
              if len(set(providers)) > 1}

(report_dir / 'rootfs-packages.tsv').write_text(''.join(
    f'{name}\t{names[name]}\n' for name in sorted(names)))
(report_dir / 'ownership.tsv').write_text(''.join(
    f'{path}\t{provider}\n' for path in sorted(owners) for provider in sorted(set(owners[path]))))
(report_dir / 'ownership-conflicts.tsv').write_text(''.join(
    f'{path}\t{" ".join(providers)}\n' for path, providers in sorted(collisions.items())))
summary = [
    f'rootfs_ipk_count={len(ipks)}',
    f'rootfs_package_count={len(names)}',
    f'libwebsockets-full={"present" if "libwebsockets-full" in names else "absent"}',
    f'libwebsockets-mbedtls={"present" if "libwebsockets-mbedtls" in names else "absent"}',
    f'ownership_conflict_count={len(collisions)}',
]
for package in sorted(required):
    summary.append(f'{package}={"present" if package in names else "absent"}')
(report_dir / 'summary.txt').write_text('\n'.join(summary) + '\n')
print('\n'.join(summary))
if missing or forbidden or collisions:
    if missing:
        print(f'Missing required rootfs packages: {", ".join(missing)}', file=sys.stderr)
    if forbidden:
        print(f'Forbidden rootfs packages present: {", ".join(forbidden)}', file=sys.stderr)
    if collisions:
        print('IPK path ownership collisions:', file=sys.stderr)
        for path, providers in sorted(collisions.items()):
            print(f'  {path}: {", ".join(providers)}', file=sys.stderr)
    raise SystemExit(1)
PYTHON

  if [ "$install_status" -ne 0 ]; then
    die "Rootfs package-install transaction failed (exit ${install_status}); see $REPORT_DIR/package-install.log"
  fi

  log "Preflight passed; report written to $REPORT_DIR"
}

main "$@"
