#!/usr/bin/env python3
"""Bump winget manifests from GitHub latest releases and submit to winget-pkgs.

With no package arguments, every package directory that contains manifests is
processed. Named arguments select individual packages (directory name,
PackageName, or PackageIdentifier).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import ssl
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WINGET_PKGS = "microsoft/winget-pkgs"
KOMAC_REPO = "russellbanks/Komac"
USER_AGENT = "siakhooi-winget-manifests-bump"
API_TIMEOUT = 60
DOWNLOAD_TIMEOUT = 300


@dataclass
class Package:
    dir_name: str
    path: Path
    identifier: str
    local_version: str
    local_dir: Path
    github_repo: str
    installer_urls: list[str]


@dataclass
class Release:
    tag: str
    version: str
    published_date: str
    html_url: str
    assets: dict[str, str]


class BumpError(Exception):
    pass


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr, flush=True)


def log(msg: str) -> None:
    print(msg, flush=True)


def version_key(version: str) -> tuple:
    parts = re.split(r"(\d+)", version)
    key = []
    for part in parts:
        if part.isdigit():
            key.append((0, int(part)))
        else:
            key.append((1, part.lower()))
    return tuple(key)


def version_from_tag(tag: str) -> str:
    if tag.startswith(("v", "V")) and len(tag) > 1 and tag[1].isdigit():
        return tag[1:]
    return tag


def yaml_field(text: str, key: str) -> str | None:
    match = re.search(rf"^{re.escape(key)}:\s*(.+?)\s*$", text, re.M)
    if not match:
        return None
    value = match.group(1).strip()
    if value[:1] in {"'", '"'}:
        value = value[1:-1]
    return value


def yaml_fields(text: str, key: str) -> list[str]:
    values = []
    for match in re.finditer(rf"^.*\b{re.escape(key)}:\s*(\S+)\s*$", text, re.M):
        values.append(match.group(1).strip())
    return values


def github_repo_from_url(url: str) -> str | None:
    match = re.search(r"github\.com/([^/]+)/([^/#\s]+)", url)
    if not match:
        return None
    return f"{match.group(1)}/{match.group(2).rstrip('/')}"


def gh_cli_token() -> str | None:
    try:
        result = subprocess.run(
            ["gh", "auth", "token"],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        return None
    token = result.stdout.strip()
    if result.returncode == 0 and token:
        return token
    return None


def api_token() -> str | None:
    for name in ("GH_TOKEN", "GITHUB_TOKEN", "WINGET_TOKEN"):
        value = os.environ.get(name)
        if value:
            return value
    return gh_cli_token()


def submit_token() -> str | None:
    for name in ("WINGET_TOKEN", "WINGET_GITHUB_TOKEN"):
        value = os.environ.get(name)
        if value:
            return value
    if os.environ.get("GITHUB_ACTIONS") == "true":
        return None
    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        value = os.environ.get(name)
        if value:
            return value
    return gh_cli_token()


def http_get(url: str, *, token: str | None = None, timeout: int = API_TIMEOUT) -> bytes:
    headers = {
        "User-Agent": USER_AGENT,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise BumpError(f"HTTP {exc.code} for {url}: {body[:500]}") from exc
    except urllib.error.URLError as exc:
        raise BumpError(f"Failed to fetch {url}: {exc.reason}") from exc


def http_get_json(url: str, *, token: str | None = None) -> object:
    return json.loads(http_get(url, token=token).decode("utf-8"))


def download_file(url: str, dest: Path, *, token: str | None = None) -> None:
    headers = {"User-Agent": USER_AGENT}
    if token and "github.com" in url:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    last_error: Exception | None = None
    for attempt in range(1, 4):
        try:
            with urllib.request.urlopen(request, timeout=DOWNLOAD_TIMEOUT) as response:
                dest.write_bytes(response.read())
            return
        except (urllib.error.URLError, TimeoutError, ssl.SSLError) as exc:
            last_error = exc
            eprint(f"    download retry {attempt}/3: {exc}")
    raise BumpError(f"Failed to download {url}: {last_error}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def find_manifest_file(version_dir: Path, kind: str) -> Path:
    if kind == "installer":
        matches = list(version_dir.glob("*.installer.yaml"))
    elif kind == "locale":
        matches = list(version_dir.glob("*.locale.en-US.yaml"))
    elif kind == "version":
        matches = [
            path
            for path in version_dir.glob("*.yaml")
            if not path.name.endswith(".installer.yaml")
            and ".locale." not in path.name
        ]
    else:
        raise BumpError(f"Unknown manifest kind {kind}")
    if not matches:
        raise BumpError(f"No {kind} manifest in {version_dir}")
    return matches[0]


def discover_packages(root: Path) -> list[Package]:
    packages: list[Package] = []
    for path in sorted(root.iterdir()):
        manifests = path / "manifests"
        if not path.is_dir() or not manifests.is_dir():
            continue
        version_dirs = [item for item in manifests.glob("*/*/*/*") if item.is_dir()]
        if not version_dirs:
            raise BumpError(f"{path.name}: no version directories under manifests/")
        local_dir = max(version_dirs, key=lambda item: version_key(item.name))
        version_yaml = find_manifest_file(local_dir, "version")
        locale_yaml = find_manifest_file(local_dir, "locale")
        installer_yaml = find_manifest_file(local_dir, "installer")
        version_text = version_yaml.read_text(encoding="utf-8")
        locale_text = locale_yaml.read_text(encoding="utf-8")
        installer_text = installer_yaml.read_text(encoding="utf-8")
        identifier = yaml_field(version_text, "PackageIdentifier")
        package_url = yaml_field(locale_text, "PackageUrl")
        if not identifier:
            raise BumpError(f"{path.name}: missing PackageIdentifier")
        if not package_url:
            raise BumpError(f"{path.name}: missing PackageUrl")
        repo = github_repo_from_url(package_url)
        if not repo:
            raise BumpError(f"{path.name}: PackageUrl is not a GitHub URL: {package_url}")
        installer_urls = yaml_fields(installer_text, "InstallerUrl")
        if not installer_urls:
            raise BumpError(f"{path.name}: no InstallerUrl entries")
        packages.append(
            Package(
                dir_name=path.name,
                path=path,
                identifier=identifier,
                local_version=local_dir.name,
                local_dir=local_dir,
                github_repo=repo,
                installer_urls=installer_urls,
            )
        )
    if not packages:
        raise BumpError(f"No package directories with manifests found in {root}")
    return packages


def resolve_selection(packages: list[Package], names: list[str]) -> list[Package]:
    if not names:
        return packages
    selected: list[Package] = []
    known = {package.dir_name for package in packages}
    for name in names:
        lowered = name.lower()
        match = next(
            (
                package
                for package in packages
                if lowered
                in {
                    package.dir_name.lower(),
                    package.identifier.lower(),
                    package.identifier.split(".")[-1].lower(),
                    package.path.name.lower(),
                }
            ),
            None,
        )
        if match is None:
            raise BumpError(
                f"Unknown package {name!r}. Known packages: {', '.join(sorted(known))}"
            )
        if match not in selected:
            selected.append(match)
    return selected


def latest_release(repo: str, token: str | None) -> Release:
    data = http_get_json(
        f"https://api.github.com/repos/{repo}/releases/latest",
        token=token,
    )
    if not isinstance(data, dict) or "tag_name" not in data:
        raise BumpError(f"{repo}: unexpected GitHub release response")
    tag = str(data["tag_name"])
    published = str(data.get("published_at") or "")
    published_date = published[:10] if published else ""
    assets = {
        str(asset["name"]): str(asset["browser_download_url"])
        for asset in data.get("assets") or []
        if asset.get("name") and asset.get("browser_download_url")
    }
    return Release(
        tag=tag,
        version=version_from_tag(tag),
        published_date=published_date,
        html_url=str(data.get("html_url") or f"https://github.com/{repo}/releases/tag/{tag}"),
        assets=assets,
    )


def winget_pkgs_versions(identifier: str, token: str | None) -> set[str]:
    first = identifier[0].lower()
    path = "/".join(identifier.split("."))
    url = f"https://api.github.com/repos/{WINGET_PKGS}/contents/manifests/{first}/{path}"
    try:
        data = http_get_json(url, token=token)
    except BumpError as exc:
        if "HTTP 404" in str(exc):
            return set()
        raise
    if not isinstance(data, list):
        return set()
    return {str(item["name"]) for item in data if item.get("type") == "dir" and item.get("name")}


def match_asset(old_url: str, old_version: str, new_version: str, assets: dict[str, str]) -> tuple[str, str]:
    old_name = old_url.rstrip("/").rsplit("/", 1)[-1]
    expected = old_name.replace(old_version, new_version, 1)
    if expected in assets:
        return expected, assets[expected]
    lowered = {name.lower(): name for name in assets}
    if expected.lower() in lowered:
        actual = lowered[expected.lower()]
        return actual, assets[actual]
    available = ", ".join(sorted(assets)) or "(none)"
    raise BumpError(
        f"Release has no installer named {expected!r} (from {old_name}). Assets: {available}"
    )


def set_yaml_field(text: str, key: str, value: str) -> str:
    pattern = rf"^({re.escape(key)}:\s*).*$"
    updated, count = re.subn(pattern, rf"\g<1>{value}", text, count=1, flags=re.M)
    if count == 0:
        raise BumpError(f"Could not update YAML field {key}")
    return updated


def bump_installer_yaml(
    text: str,
    *,
    version: str,
    release_date: str,
    replacements: dict[str, tuple[str, str]],
) -> str:
    text = set_yaml_field(text, "PackageVersion", version)
    if release_date:
        if re.search(r"^ReleaseDate:\s*", text, re.M):
            text = set_yaml_field(text, "ReleaseDate", release_date)
        else:
            text = re.sub(
                r"^(PackageVersion:\s*.*)$",
                rf"\1\nReleaseDate: {release_date}",
                text,
                count=1,
                flags=re.M,
            )
    lines = text.splitlines(keepends=True)
    pending_sha: str | None = None
    out: list[str] = []
    for line in lines:
        if re.search(r"\bInstallerUrl:", line):
            old_url = line.split("InstallerUrl:", 1)[1].strip()
            if old_url in replacements:
                new_url, new_sha = replacements[old_url]
                line = line.replace(old_url, new_url)
                pending_sha = new_sha
        elif pending_sha is not None and re.search(r"\bInstallerSha256:", line):
            prefix, current = line.split("InstallerSha256:", 1)
            old_sha = current.strip()
            sha = pending_sha.upper() if old_sha.isupper() else pending_sha.lower()
            newline = "\n" if line.endswith("\n") else ""
            line = f"{prefix}InstallerSha256: {sha}{newline}"
            pending_sha = None
        out.append(line)
    return "".join(out)


def write_manifests(
    package: Package,
    release: Release,
    replacements: dict[str, tuple[str, str]],
    dry_run: bool,
) -> Path:
    dest = package.local_dir.parent / release.version
    if dry_run:
        log(f"    would write manifests to {dest.relative_to(ROOT)}")
        return dest
    dest.mkdir(parents=True, exist_ok=True)
    for source in package.local_dir.iterdir():
        if not source.is_file() or source.suffix not in {".yaml", ".yml"}:
            continue
        text = source.read_text(encoding="utf-8")
        if source.name.endswith(".installer.yaml"):
            text = bump_installer_yaml(
                text,
                version=release.version,
                release_date=release.published_date,
                replacements=replacements,
            )
        else:
            text = set_yaml_field(text, "PackageVersion", release.version)
            if ".locale." in source.name:
                notes_url = release.html_url
                if yaml_field(text, "ReleaseNotesUrl"):
                    text = set_yaml_field(text, "ReleaseNotesUrl", notes_url)
        (dest / source.name).write_text(text, encoding="utf-8", newline="\n")
    log(f"    wrote {dest.relative_to(ROOT)}")
    return dest


def update_justfile(package: Package, new_version: str, dry_run: bool) -> None:
    justfile = package.path / "justfile"
    if not justfile.exists():
        return
    text = justfile.read_text(encoding="utf-8")
    updated, count = re.subn(
        r'^(packageVersion\s*:=\s*)"[^"]*"',
        rf'\g<1>"{new_version}"',
        text,
        count=1,
        flags=re.M,
    )
    if count == 0:
        return
    if dry_run:
        log(f"    would set {justfile.relative_to(ROOT)} packageVersion := \"{new_version}\"")
        return
    justfile.write_text(updated, encoding="utf-8", newline="\n")
    log(f"    updated {justfile.relative_to(ROOT)}")


def komac_triplet() -> str:
    system = sys.platform
    machine = platform.machine().lower()
    if machine in {"x86_64", "amd64"}:
        arch = "x86_64"
    elif machine in {"aarch64", "arm64"}:
        arch = "aarch64"
    else:
        raise BumpError(f"Unsupported CPU architecture: {platform.machine()}")
    if system == "linux":
        return f"{arch}-unknown-linux-gnu.tar.gz"
    if system == "darwin":
        return f"{arch}-apple-darwin.tar.gz"
    if system == "win32":
        return f"{arch}-pc-windows-msvc.exe"
    raise BumpError(f"Unsupported OS: {system}. Run on Linux (preferred) or install komac yourself.")


def ensure_komac(token: str | None) -> str:
    existing = shutil.which("komac")
    if existing:
        return existing
    data = http_get_json(f"https://api.github.com/repos/{KOMAC_REPO}/releases/latest", token=token)
    tag = str(data["tag_name"])
    version = version_from_tag(tag)
    suffix = komac_triplet()
    asset_name = f"komac-{version}-{suffix}"
    assets = {
        str(asset["name"]): str(asset["browser_download_url"])
        for asset in data.get("assets") or []
    }
    if asset_name not in assets:
        raise BumpError(f"komac release {tag} has no asset {asset_name}")
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "winget-manifests"
    cache.mkdir(parents=True, exist_ok=True)
    binary_name = f"komac-{version}.exe" if suffix.endswith(".exe") else f"komac-{version}"
    binary = cache / binary_name
    if binary.exists():
        return str(binary)
    log(f"    installing komac {tag} ({asset_name})")
    with tempfile.TemporaryDirectory(prefix="komac-") as tmp:
        tmpdir = Path(tmp)
        archive = tmpdir / asset_name
        download_file(assets[asset_name], archive)
        if asset_name.endswith(".exe"):
            shutil.copy2(archive, binary)
        else:
            with tarfile.open(archive) as tar:
                member = next(
                    (
                        item
                        for item in tar.getmembers()
                        if Path(item.name).name in {"komac", "komac.exe"} and item.isfile()
                    ),
                    None,
                )
                if member is None:
                    raise BumpError(f"komac binary not found in {asset_name}")
                extract_kw = {"path": tmpdir}
                try:
                    tar.extract(member, filter="data", **extract_kw)
                except TypeError:
                    tar.extract(member, **extract_kw)
                extracted = tmpdir / member.name
                shutil.copy2(extracted, binary)
    binary.chmod(binary.stat().st_mode | 0o111)
    return str(binary)


def submit_manifest(manifest_dir: Path, token: str | None, dry_run: bool) -> None:
    if dry_run:
        log(f"    would submit {manifest_dir.relative_to(ROOT)} to {WINGET_PKGS}")
        return
    in_actions = os.environ.get("GITHUB_ACTIONS") == "true"
    if not token and in_actions:
        raise BumpError(
            "No token available to submit to microsoft/winget-pkgs. "
            "Set repository secret WINGET_TOKEN to a classic PAT with public_repo "
            "(from an account that has a fork of microsoft/winget-pkgs)."
        )
    komac = ensure_komac(token)
    cmd = [komac, "submit", "--yes", str(manifest_dir)]
    env = os.environ.copy()
    if token:
        env["GITHUB_TOKEN"] = token
    log(f"    submitting {manifest_dir.relative_to(ROOT)} to {WINGET_PKGS}")
    result = subprocess.run(cmd, check=False, env=env)
    if result.returncode != 0:
        raise BumpError(f"komac submit failed with exit code {result.returncode}")


def bump_package(
    package: Package,
    *,
    token: str | None,
    winget_token: str | None,
    dry_run: bool,
    skip_submit: bool,
) -> str:
    log(f"==> {package.dir_name} ({package.identifier})")
    release = latest_release(package.github_repo, token)
    published = winget_pkgs_versions(package.identifier, token)
    log(f"    GitHub:     {release.tag} ({release.version})")
    log(f"    local:      {package.local_version}")
    log(f"    winget-pkgs:{' ' + ', '.join(sorted(published, key=version_key)) if published else ' none'}")

    dest = package.local_dir.parent / release.version
    need_write = not dest.exists()
    need_submit = release.version not in published

    if version_key(release.version) < version_key(package.local_version):
        log("    skip: local version is newer than GitHub latest")
        return "skipped"

    replacements: dict[str, tuple[str, str]] = {}
    if need_write:
        for old_url in package.installer_urls:
            name, new_url = match_asset(
                old_url, package.local_version, release.version, release.assets
            )
            replacements[old_url] = (new_url, "")
            log(f"    installer:  {name}")
        if dry_run:
            write_manifests(package, release, replacements, dry_run=True)
            update_justfile(package, release.version, dry_run=True)
        else:
            with tempfile.TemporaryDirectory(prefix=f"{package.dir_name}-") as tmp:
                tmpdir = Path(tmp)
                hashed: dict[str, tuple[str, str]] = {}
                for old_url, (new_url, _) in replacements.items():
                    filename = new_url.rstrip("/").rsplit("/", 1)[-1]
                    dest_file = tmpdir / filename
                    log(f"    downloading {filename}")
                    download_file(new_url, dest_file)
                    hashed[old_url] = (new_url, sha256_file(dest_file))
                dest = write_manifests(package, release, hashed, dry_run=False)
            update_justfile(package, release.version, dry_run=False)
    else:
        log("    local manifests already at latest GitHub version")

    if skip_submit:
        log("    skip submit (--skip-submit)")
        return "updated" if need_write else "current"

    if not need_submit:
        log("    skip submit: already in microsoft/winget-pkgs")
        return "current"

    submit_manifest(dest, winget_token, dry_run)
    return "submitted"


def append_step_summary(lines: list[str]) -> None:
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary:
        return
    with Path(summary).open("a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create latest winget manifests from GitHub releases and submit them to microsoft/winget-pkgs.",
    )
    parser.add_argument(
        "packages",
        nargs="*",
        help="Package directory names (default: all). Also accepts PackageName or PackageIdentifier.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would change without writing files or submitting PRs.",
    )
    parser.add_argument(
        "--skip-submit",
        action="store_true",
        help="Write local manifests only; do not open a winget-pkgs PR.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    expanded: list[str] = []
    for name in args.packages:
        expanded.extend(part for part in re.split(r"[,\s]+", name) if part)
    args.packages = expanded
    dry_run = args.dry_run or os.environ.get("DRY_RUN") == "1"
    skip_submit = args.skip_submit or os.environ.get("SKIP_SUBMIT") == "1"
    token = api_token()
    winget_token = submit_token()

    try:
        packages = resolve_selection(discover_packages(ROOT), args.packages)
    except BumpError as exc:
        eprint(f"error: {exc}")
        return 2

    failures: list[str] = []
    results: list[str] = ["| Package | Result |", "| --- | --- |"]
    for package in packages:
        try:
            status = bump_package(
                package,
                token=token,
                winget_token=winget_token,
                dry_run=dry_run,
                skip_submit=skip_submit,
            )
            results.append(f"| {package.dir_name} | {status} |")
        except BumpError as exc:
            eprint(f"error: {package.dir_name}: {exc}")
            failures.append(package.dir_name)
            results.append(f"| {package.dir_name} | failed |")
        log("")

    append_step_summary(["## WinGet bump", ""] + results)
    if failures:
        eprint("failed: " + ", ".join(failures))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
