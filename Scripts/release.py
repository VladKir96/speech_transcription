"""Build and, when explicitly requested, publish LocalCaption distribution artifacts."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


INFO = Path("AppResources/Info.plist")
SPARKLE = Path(".deps/sparkle/bin").resolve()
ACCOUNT = "local.caption.macos"
BUNDLE_ID = "local.caption.macos"
ASSETS = ("LocalCaption.dmg", "LocalCaption.zip", "appcast.xml", "SHA256SUMS")
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
GIT = ("git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential")


class ReleaseError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def run(*command, capture=False, **kwargs):
    result = subprocess.run(command, check=True, text=True, capture_output=capture, **kwargs)
    return result.stdout.strip() if capture else None


def read(*command):
    return run(*command, capture=True)


def version_tuple(version):
    require(VERSION.fullmatch(version), "Use a stable semantic version in X.Y.Z format.")
    return tuple(map(int, version.split(".")))


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def app_plist(app):
    return plistlib.loads((app / "Contents/Info.plist").read_bytes())


def check_app(app, metadata):
    info = app_plist(app)
    repository = metadata["repository"]
    require(info["CFBundleIdentifier"] == BUNDLE_ID
            and info["CFBundleShortVersionString"] == metadata["version"]
            and info["CFBundleVersion"] == metadata["build"]
            and info["SUFeedURL"] == f"https://github.com/{repository}/releases/latest/download/appcast.xml"
            and info["SUPublicEDKey"] == metadata["publicKey"]
            and info["SUVerifyUpdateBeforeExtraction"] is True
            and info["SURequireSignedFeed"] is True
            and info["SUEnableAutomaticChecks"] is False
            and info["SUAllowsAutomaticUpdates"] is False
            and info["SUScheduledCheckInterval"] == 86400,
            "The app bundle has incorrect version or updater metadata.")
    run("codesign", "--verify", "--deep", "--strict", app)
    executable = app / "Contents/MacOS/LocalCaption"
    require(read("lipo", "-archs", executable) == "arm64" and os.access(executable, os.X_OK),
            "The app executable must be executable and arm64.")
    frameworks = app / "Contents/Frameworks"
    require((frameworks / "Sparkle.framework/Versions/Current").is_symlink(),
            "The Sparkle framework symlinks are missing.")
    for path in [executable, *frameworks.glob("*.dylib")]:
        for line in read("otool", "-L", path).splitlines()[1:]:
            library = line.strip().split(" (compatibility version", 1)[0]
            if library.startswith("@rpath/"):
                require((frameworks / library.removeprefix("@rpath/")).exists()
                        or library == "@rpath/libswift_Concurrency.dylib",
                        f"Missing bundled dependency: {library}")
            else:
                require(library.startswith(("/usr/lib/", "/System/Library/")),
                        f"Unexpected dependency: {library}")
    if metadata["profile"] == "developer-id":
        run("xcrun", "stapler", "validate", app)


def check_signatures(folder, metadata):
    feed = folder / "appcast.xml"
    account = metadata["account"]
    run(SPARKLE / "sign_update", "--account", account, "--verify", feed)
    items = ET.parse(feed).findall("channel/item")
    require(len(items) == 1, "Expected one update in the appcast.")
    item = items[0]
    enclosure = item.find("enclosure")
    archive = folder / "LocalCaption.zip"
    expected = f'https://github.com/{metadata["repository"]}/releases/download/v{metadata["version"]}/LocalCaption.zip'
    require(enclosure is not None and enclosure.get("url") == expected
            and enclosure.get("length") == str(archive.stat().st_size)
            and item.findtext(NS + "version") == metadata["build"]
            and item.findtext(NS + "shortVersionString") == metadata["version"]
            and (item.findtext("description") or "").strip()
            and enclosure.get(NS + "edSignature"), "Incorrect version, notes, or enclosure in appcast.")
    run(SPARKLE / "sign_update", "--account", account, "--verify", archive, enclosure.get(NS + "edSignature"))


def check_artifacts(folder, metadata):
    require((folder / "SHA256SUMS").read_text() == checksums(folder), "Release asset checksums changed.")
    require(digest(folder / "LocalCaption.md") == metadata["notesDigest"], "Release notes changed.")
    check_signatures(folder, metadata)
    app = folder / "LocalCaption.app"
    check_app(app, metadata)
    image = folder / "LocalCaption.dmg"
    run("hdiutil", "verify", image)
    if metadata["profile"] == "developer-id":
        run("codesign", "--verify", "--strict", image)
        run("xcrun", "stapler", "validate", image)
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", image)
    with tempfile.TemporaryDirectory(dir=folder, prefix=".verify-") as temporary:
        work = Path(temporary)
        run("ditto", "-x", "-k", folder / "LocalCaption.zip", work)
        check_app(work / app.name, metadata)
        require(digest(work / app.name / "Contents/MacOS/LocalCaption") ==
                digest(app / "Contents/MacOS/LocalCaption"), "ZIP contains a different executable.")
        mount = work / "mounted"
        mount.mkdir()
        run("hdiutil", "attach", image, "-readonly", "-nobrowse", "-mountpoint", mount)
        try:
            require((mount / "Applications").is_symlink()
                    and os.readlink(mount / "Applications") == "/Applications",
                    "The installer needs an Applications shortcut.")
            check_app(mount / app.name, metadata)
            require(digest(mount / app.name / "Contents/MacOS/LocalCaption") ==
                    digest(app / "Contents/MacOS/LocalCaption"), "DMG contains a different executable.")
        finally:
            run("hdiutil", "detach", mount)


def checksums(folder):
    return "".join(f"{digest(folder / name)}  {name}\n" for name in ASSETS[:-1])


def release_notes(version, notes, previous_tag):
    path = notes or Path("ReleaseNotes") / f"{version}.md"
    if notes or path.is_file():
        content = path.read_text(encoding="utf-8").strip()
        require(content, "The release notes file is empty.")
        return content + "\n"
    revision = f"{previous_tag}..HEAD" if previous_tag else "HEAD"
    subjects = read("git", "log", "--no-merges", "--format=%s", revision).splitlines()
    changes = [match.group(1) for subject in subjects
               if (match := re.fullmatch(r"(?:feat|fix|perf)(?:\([^)]*\))?!?: (.+)", subject))]
    bullets = "\n".join(f"- {change}" for change in changes)
    return f"## LocalCaption {version}\n\n{bullets or 'Install or update LocalCaption on Apple Silicon.'}\n"


def signing(profile):
    identity = os.environ.get("LOCALCAPTION_SIGN_IDENTITY", "-")
    notary_profile = os.environ.get("LOCALCAPTION_NOTARY_PROFILE")
    if profile == "developer-id":
        require(identity.startswith("Developer ID Application:") and notary_profile,
                "Set LOCALCAPTION_SIGN_IDENTITY to a Developer ID Application identity and "
                "LOCALCAPTION_NOTARY_PROFILE to a notarytool Keychain profile.")
    else:
        require(identity == "-" or identity.startswith(("Apple Development:", "Mac Developer:")),
                "Use ad hoc or a local Apple Development identity for personal distribution.")
    if identity != "-":
        require(f'"{identity}"' in read("security", "find-identity", "-v", "-p", "codesigning"),
                "The requested Apple code-signing identity is unavailable in Keychain.")
    if profile == "developer-id":
        run("xcrun", "notarytool", "history", "--keychain-profile", notary_profile, capture=True)
    return identity, notary_profile


def notarize(path, profile, staple):
    run("xcrun", "notarytool", "submit", path, "--keychain-profile", profile, "--wait")
    run("xcrun", "stapler", "staple", staple)
    run("xcrun", "stapler", "validate", staple)


def build(folder, metadata, notes, info, identity, notary_profile):
    require(not folder.exists(), f"{folder} already exists. Keep it or move it before building again.")
    folder.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=folder.parent, prefix=".stage-") as temporary:
        work = Path(temporary)
        output = work / "artifacts"
        output.mkdir()
        staged_plist = work / "Info.plist"
        staged_plist.write_bytes(info)
        run(sys.executable, "-B", "-m", "unittest", "discover", "-s", "Scripts", "-p", "test_release.py")
        run("./Scripts/test.sh")
        run("./Scripts/build-app.sh", env={
            **os.environ, "LOCALCAPTION_CONFIGURATION": "release", "LOCALCAPTION_INFO_PLIST": str(staged_plist),
            "LOCALCAPTION_OUTPUT_DIRECTORY": str(output), "LOCALCAPTION_SIGN_IDENTITY": identity,
        })
        app = output / "LocalCaption.app"
        image_source = work / "image"
        image_source.mkdir()
        (image_source / "Applications").symlink_to("/Applications")
        if metadata["profile"] == "developer-id":
            submission = work / "notarization.zip"
            run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, submission)
            notarize(submission, notary_profile, app)
        run("ditto", app, image_source / app.name)
        image = output / "LocalCaption.dmg"
        run("hdiutil", "create", "-volname", "LocalCaption", "-srcfolder", image_source,
            "-format", "UDZO", "-ov", image)
        if metadata["profile"] == "developer-id":
            run("codesign", "--sign", identity, "--timestamp", image)
            notarize(image, notary_profile, image)
        sparkle_source = work / "updates"
        sparkle_source.mkdir()
        archive = sparkle_source / "LocalCaption.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
        (sparkle_source / "LocalCaption.md").write_text(notes, encoding="utf-8")
        project = f'https://github.com/{metadata["repository"]}'
        run(SPARKLE / "generate_appcast", "--account", metadata["account"],
            "--download-url-prefix", f'{project}/releases/download/v{metadata["version"]}/',
            "--link", f"{project}/releases", "--embed-release-notes",
            "--maximum-versions", "1", "--maximum-deltas", "0", sparkle_source)
        for name in ("LocalCaption.zip", "appcast.xml", "LocalCaption.md"):
            (sparkle_source / name).rename(output / name)
        (output / "SHA256SUMS").write_text(checksums(output))
        metadata["notesDigest"] = digest(output / "LocalCaption.md")
        (output / ".release.json").write_text(json.dumps(metadata, indent=2) + "\n")
        check_artifacts(output, metadata)
        output.rename(folder)
    print(f"Validated release artifacts in {folder}", flush=True)


def release_view(repo, tag):
    result = subprocess.run(["gh", "release", "view", tag, "--repo", repo,
                             "--json", "isDraft,url,assets"], text=True, capture_output=True)
    if result.returncode == 0:
        return json.loads(result.stdout)
    require("release not found" in result.stderr.lower(), result.stderr.strip() or "Could not query the release.")
    return None


def remote_refs(*options):
    return {ref: sha for sha, ref in (line.split() for line in
            read(*GIT, "ls-remote", *options).splitlines())}


def check_github(repository):
    require(shutil.which("gh"), "Install GitHub CLI and run gh auth login.")
    try:
        result = json.loads(read("gh", "api", "--hostname", "github.com", f"repos/{repository}"))
    except subprocess.CalledProcessError as error:
        raise ReleaseError("Cannot query GitHub. Check connectivity and run gh auth status or gh auth login.") from error
    branch = read("git", "symbolic-ref", "--short", "HEAD")
    require(result["default_branch"] == branch, f"Switch to the default branch ({result['default_branch']}).")
    require(not result["private"] and result.get("permissions", {}).get("push"),
            "A public GitHub repository and permission to publish releases are required.")
    push_repo = read("bash", "-c", 'source Scripts/github-origin.sh; github_repository --push origin')
    require(push_repo.lower() == repository.lower(), "Fetch and push origin must refer to the same GitHub repository.")
    return branch


def latest_tag(version, tags, resuming):
    target = f"v{version}"
    stable = [tag for tag in set(tags) if tag.startswith("v") and VERSION.fullmatch(tag[1:])]
    require(resuming or target not in stable, f"Tag {target} already exists.")
    older = [tag for tag in stable if tag != target]
    previous = max(older, key=lambda tag: version_tuple(tag[1:]), default=None)
    require(previous is None or version_tuple(version) > version_tuple(previous[1:]),
            f"The version must be newer than {previous}.")
    return previous


def release_commit(metadata, info):
    head = read("git", "rev-parse", "HEAD")
    source = metadata["source"]
    if head == source:
        original = INFO.read_bytes()
        INFO.write_bytes(info)
        try:
            run("git", "commit", "--only", "-m", f'Release LocalCaption {metadata["version"]}', "--", INFO)
        except subprocess.CalledProcessError:
            INFO.write_bytes(original)
            raise
        return read("git", "rev-parse", "HEAD")
    require(read("git", "rev-parse", "HEAD^") == source
            and read("git", "diff-tree", "--no-commit-id", "--name-only", "-r", head) == str(INFO)
            and INFO.read_bytes() == info,
            "Current HEAD must match the candidate source or its release version commit.")
    return head


def bump_info(source, version, build_number):
    info = source.decode("utf-8")
    for key, value in (("CFBundleShortVersionString", version), ("CFBundleVersion", build_number)):
        pattern = rf"(<key>{key}</key>\s*<string>)[^<]+(</string>)"
        info, matches = re.subn(pattern, lambda match: f"{match[1]}{value}{match[2]}", info)
        require(matches == 1, f"Expected one {key} in {INFO}.")
    return info.encode("utf-8")


def verify_public(folder, repository, tag):
    base = f"https://github.com/{repository}/releases"
    with tempfile.TemporaryDirectory(dir=folder, prefix=".public-") as temporary:
        copy = Path(temporary) / "asset"
        for url, name in [(f"{base}/latest/download/appcast.xml", "appcast.xml"),
                          (f"{base}/download/{tag}/LocalCaption.zip", "LocalCaption.zip")]:
            run("curl", "-q", "--fail", "--location", "--silent", "--show-error", "--retry", "5",
                "--retry-all-errors", "--proto", "=https", "--proto-redir", "=https", "--output", copy, url)
            require(digest(copy) == digest(folder / name), f"Public release asset differs: {url}")


def publish(folder, metadata, info, branch, remote_tags):
    repository = metadata["repository"]
    tag = f'v{metadata["version"]}'
    ref = f"refs/tags/{tag}"
    release = release_view(repository, tag)
    if release and not release["isDraft"]:
        require(remote_tags.get(f"{ref}^{{}}", remote_tags.get(ref)) == read("git", "rev-parse", "HEAD")
                and INFO.read_bytes() == info, "A different published release already uses this tag.")
        verify_public(folder, repository, tag)
        print(release["url"])
        return

    branch_ref = f"refs/heads/{branch}"
    remote_branch = remote_refs("--heads", "origin", branch_ref).get(branch_ref)
    require(remote_branch, f"Remote branch {branch} is missing.")
    release_sha = release_commit(metadata, info)
    if ref in remote_tags:
        require(remote_tags.get(f"{ref}^{{}}", remote_tags[ref]) == release_sha,
                f"Existing remote tag {tag} points to a different commit.")
    else:
        require(not release, f"Draft release {tag} already exists without the expected remote tag.")
        require(subprocess.run(["git", "merge-base", "--is-ancestor", remote_branch, release_sha]).returncode == 0,
                "The remote branch has moved. Reconcile the branch before publishing.")
        if read("git", "tag", "--list", tag):
            require(read("git", "rev-parse", f"{tag}^{{commit}}") == release_sha,
                    f"Existing local tag {tag} points to a different commit.")
        else:
            run("git", "tag", "-a", tag, "-m", f"LocalCaption {tag}", release_sha)
        run(*GIT, "push", "--atomic", "origin", f"HEAD:{branch_ref}", f"{ref}:{ref}")

    if not release:
        run("gh", "release", "create", tag, "--repo", repository, "--verify-tag", "--draft",
            "--title", f"LocalCaption {tag}", "--notes-file", folder / "LocalCaption.md")
        release = release_view(repository, tag)
    require(release and release["isDraft"], "Could not confirm the GitHub draft.")
    uploaded = {asset["name"]: asset for asset in release["assets"]}
    require(uploaded.keys() <= set(ASSETS), "The draft contains unexpected custom assets.")
    for name in ASSETS:
        if name not in uploaded:
            run("gh", "release", "upload", tag, folder / name, "--repo", repository)
    release = release_view(repository, tag)
    require(release and release["isDraft"], "The draft changed during upload.")
    uploaded = {asset["name"]: asset for asset in release["assets"]}
    require(uploaded.keys() == set(ASSETS), "The draft does not contain the expected release assets.")
    for name in ASSETS:
        asset = uploaded[name]
        require(asset["state"] == "uploaded" and asset["size"] == (folder / name).stat().st_size
                and (not asset.get("digest") or asset["digest"] == f"sha256:{digest(folder / name)}"),
                f"Draft asset mismatch: {name}. Remove the incomplete asset from the draft before retrying.")
    with tempfile.TemporaryDirectory(dir=folder, prefix=".draft-") as temporary:
        options = [flag for name in ASSETS for flag in ("--pattern", name)]
        run("gh", "release", "download", tag, "--repo", repository, "--dir", temporary, *options)
        for name in ASSETS:
            require(digest(Path(temporary) / name) == digest(folder / name), f"Draft asset differs: {name}")

    run("gh", "release", "edit", tag, "--repo", repository, "--verify-tag", "--draft=false", "--latest",
        "--notes-file", folder / "LocalCaption.md")
    print(f"Published {tag}. Verifying public update downloads…", flush=True)
    verify_public(folder, repository, tag)
    print(release_view(repository, tag)["url"])


def main():
    parser = argparse.ArgumentParser(prog="./Scripts/release.sh", description=__doc__)
    parser.add_argument("version", help="Stable semantic version, for example 1.5.0")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--build-only", action="store_true", help="Build locally without changing Git or GitHub (default)")
    mode.add_argument("--publish", action="store_true", help="Commit, tag, push and publish after validation")
    parser.add_argument("--resume", action="store_true", help="Reuse the saved artifacts to resume publication")
    parser.add_argument("--notes", type=Path, help="Markdown file to show in GitHub and Sparkle")
    parser.add_argument("--signing", choices=("personal", "developer-id"), default="personal")
    args = parser.parse_args()
    require(not args.resume or (args.publish and not args.notes), "--resume requires --publish and uses the saved notes.")
    version = version_tuple(args.version)
    repository = os.environ["LOCALCAPTION_RELEASE_REPOSITORY"]
    tag = f"v{args.version}"
    folder = (Path("dist") / ("releases" if args.publish else "release-candidates") / tag).resolve()
    require(os.uname().machine == "arm64", "Build on Apple Silicon using an arm64 shell.")
    require(not args.publish or not read("git", "status", "--porcelain"), "Commit or stash local changes first.")
    branch = check_github(repository) if args.publish else None
    remote_tags = remote_refs("--tags", "origin") if args.publish else {}
    previous = latest_tag(args.version, [*read("git", "tag", "--list").splitlines(),
                          *(ref.removeprefix("refs/tags/") for ref in remote_tags)], args.resume)
    if args.publish and not args.resume:
        require(not release_view(repository, tag), f"GitHub release {tag} already exists.")
    run("bash", "Scripts/bootstrap-sparkle.sh")
    try:
        public = read(SPARKLE / "generate_keys", "--account", ACCOUNT, "-p")
    except subprocess.CalledProcessError as error:
        raise ReleaseError("Restore the LocalCaption Sparkle key in Keychain as described in RELEASE.md.") from error

    if args.resume:
        metadata = json.loads((folder / ".release.json").read_text())
        require(metadata["version"] == args.version and metadata["repository"] == repository
                and metadata["account"] == ACCOUNT and metadata["publicKey"] == public,
                "Saved release assets are for a different version, repository, or signing key.")
        source = subprocess.check_output(["git", "show", f'{metadata["source"]}:{INFO}'])
    else:
        source = INFO.read_bytes()
        metadata = {
            "version": args.version, "build": str(int(plistlib.loads(source)["CFBundleVersion"]) + 1),
            "repository": repository, "source": read("git", "rev-parse", "HEAD"),
            "profile": args.signing, "account": ACCOUNT, "publicKey": public,
        }
    base_info = plistlib.loads(source)
    require(version > version_tuple(base_info["CFBundleShortVersionString"]),
            f'The version must be newer than {base_info["CFBundleShortVersionString"]}.')
    require(public == base_info["SUPublicEDKey"], "The Keychain public key does not match the bundled policy.")
    require(metadata["build"] == str(int(base_info["CFBundleVersion"]) + 1), "Incorrect saved build number.")
    info = bump_info(source, args.version, metadata["build"])
    if args.resume:
        check_artifacts(folder, metadata)
    else:
        identity, notary_profile = signing(args.signing)
        build(folder, metadata, release_notes(args.version, args.notes, previous), info, identity, notary_profile)
    if args.publish:
        try:
            publish(folder, metadata, info, branch, remote_tags)
        except (ReleaseError, subprocess.CalledProcessError, OSError):
            print(f"To resume publication or verification with the saved artifacts, run "
                  f"./Scripts/release.sh {args.version} --publish --resume", file=sys.stderr)
            raise


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, subprocess.CalledProcessError, OSError, ValueError) as error:
        print(f"Release failed: {error}", file=sys.stderr)
        sys.exit(1)
